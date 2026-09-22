"""Embedding via a local Ollama server.

Ollama serializes model execution, so client-side fan-out adds contention rather
than throughput. One batching producer is the right shape: large batches per
request, requests issued one at a time.

Embeddings are written through :func:`backfill_model`, which inserts only chunks
the target model is missing. That single property is what makes "index with a
cheap model now, re-index with a better one later" a routine operation instead of
a migration -- adding a model never touches another model's vectors, and never
re-reads a source file.
"""

from __future__ import annotations

import logging
from collections.abc import Iterator, Sequence
from dataclasses import dataclass

import ollama
from pgvector import HalfVector
from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.db.emb_tables import assert_safe_table
from garage_rag.db.models import EmbeddingModel
from garage_rag.db.registry import StoragePlan, truncate_vector
from garage_rag.embed.base import Embedder, EmbeddingError

log = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)

# ``EmbeddingError`` is defined once in ``embed.base``; it stays importable from
# here because the CLI and the gRPC service catch it under this name.
__all__ = [
    "BackfillProgress",
    "EmbeddingError",
    "OllamaEmbedder",
    "backfill_model",
    "count_pending",
    "verify_model_dims",
]


@dataclass
class BackfillProgress:
    total: int = 0
    embedded: int = 0
    failed: int = 0
    batches: int = 0

    @property
    def remaining(self) -> int:
        return max(0, self.total - self.embedded - self.failed)


class OllamaEmbedder(Embedder):
    """Batched embedding client for one registered model."""

    provider_name = "ollama"

    def __init__(self, model_ref: str, *, host: str | None = None) -> None:
        settings = get_settings()
        self.model_ref = model_ref
        self._client = ollama.Client(host=host or settings.ollama_host)

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        response = self._client.embed(model=self.model_ref, input=texts)
        return response.get("embeddings") if isinstance(response, dict) else response.embeddings


def _plan_from_row(row: EmbeddingModel) -> StoragePlan:
    return StoragePlan(
        stored_dims=row.stored_dims,
        storage_kind=row.storage_kind,
        index_kind=row.index_kind,
        truncated_from=row.dims if row.stored_dims < row.dims else None,
    )


def _adapt(values: list[float], plan: StoragePlan):
    """Convert one embedding into the value type its column expects."""
    reduced = truncate_vector(values, plan)
    # halfvec columns need an explicit HalfVector; plain lists bind as vector.
    return HalfVector(reduced) if plan.storage_kind == "halfvec" else reduced


def _pending_chunk_batches(session: Session, table: str, batch_size: int) -> Iterator[list[tuple[int, str]]]:
    """Yield batches of (chunk_id, text) that ``table`` has no vector for.

    Re-queried each iteration rather than held open: the anti-join shrinks as
    rows are inserted, so this converges without keeping a long-lived cursor
    across the write transactions.
    """
    sql = text(
        f"""
        SELECT c.id, c.text
        FROM chunks c
        LEFT JOIN {table} e ON e.chunk_id = c.id
        WHERE e.chunk_id IS NULL
        ORDER BY c.id
        LIMIT :limit
        """
    )
    while True:
        rows = session.execute(sql, {"limit": batch_size}).all()
        if not rows:
            return
        yield [(int(cid), txt) for cid, txt in rows]


def count_pending(session: Session, model: EmbeddingModel) -> int:
    table = assert_safe_table(model.table_name)
    return int(
        session.execute(
            text(f"SELECT count(*) FROM chunks c LEFT JOIN {table} e ON e.chunk_id = c.id WHERE e.chunk_id IS NULL")
        ).scalar_one()
    )


def backfill_model(
    session: Session,
    model: EmbeddingModel,
    *,
    batch_size: int | None = None,
    limit: int | None = None,
    progress=None,
) -> BackfillProgress:
    """Embed every chunk this model is missing.

    Pure insert: existing vectors are never touched, so this is safe to run
    repeatedly and safe to interrupt.
    """
    from garage_rag.embed.factory import get_embedder

    settings = get_settings()
    size = batch_size or settings.embed_batch_size
    table = assert_safe_table(model.table_name)
    plan = _plan_from_row(model)
    embedder = get_embedder(model.provider, model.model_ref)

    state = BackfillProgress(total=count_pending(session, model))
    if state.total == 0:
        return state

    insert_sql = text(
        f"INSERT INTO {table} (chunk_id, embedding) VALUES (:chunk_id, :embedding) ON CONFLICT (chunk_id) DO NOTHING"
    )

    for batch in _pending_chunk_batches(session, table, size):
        ids = [cid for cid, _ in batch]
        texts = [txt for _, txt in batch]
        try:
            vectors = embedder.embed(texts)
            # Check the width before touching the column: a vector of the wrong
            # size would be rejected by pgvector anyway, and a model that emits
            # the wrong width does so for every batch.
            for vec in vectors:
                if len(vec) != model.dims:
                    raise EmbeddingError(
                        f"{model.model_ref} returned a {len(vec)}-dim vector; registered as {model.dims}"
                    )
        except Exception as exc:  # noqa: BLE001 - logged and counted, never re-raised
            log.error("batch failed (%d chunks): %s", len(batch), exc)
            state.failed += len(batch)
            # A backend that is down (or mis-registered) will fail every
            # subsequent batch too.
            break

        session.execute(
            insert_sql,
            [{"chunk_id": cid, "embedding": _adapt(vec, plan)} for cid, vec in zip(ids, vectors, strict=True)],
        )
        session.commit()

        state.embedded += len(batch)
        state.batches += 1
        if progress is not None:
            progress(state)
        if limit is not None and state.embedded >= limit:
            break

    return state


def verify_model_dims(model: EmbeddingModel) -> tuple[bool, int]:
    """Check the registered width against what the model actually emits.

    A mismatch means every vector would be rejected by the column type, so it is
    worth one probe request before spending hours on a backfill.
    """
    from garage_rag.embed.factory import get_embedder

    actual = get_embedder(model.provider, model.model_ref).probe_dims()
    return actual == model.dims, actual
