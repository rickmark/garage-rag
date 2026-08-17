"""Embedding model registry: mapping a model's width onto pgvector storage.

pgvector 0.8.x index ceilings drive every decision here:

======== =============== ==================
type     max stored dims max HNSW dims
======== =============== ==================
vector   16000           2000
halfvec  16000           4000
bit      --              64000
======== =============== ==================

So a 4096-dim model (Qwen3-Embedding-8B) cannot be HNSW-indexed as-is. Two ways
out, in preference order:

1. Matryoshka truncation to <= 4000 and store as ``halfvec``. Only valid for
   models trained with MRL, where prefixes of the vector are themselves valid
   embeddings. Truncating a non-MRL model silently destroys retrieval quality,
   which is why ``supports_mrl`` must be declared per model rather than assumed.
2. Store the full-width ``vector`` unindexed, and put the HNSW index on
   ``binary_quantize(embedding)::bit(dims)`` with ``bit_hamming_ops``. Queries
   over-fetch on Hamming distance, then re-rank on exact cosine.

These functions are pure so the mapping can be tested without a database.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

# pgvector HNSW ceilings.
HNSW_MAX_VECTOR_DIMS = 2000
HNSW_MAX_HALFVEC_DIMS = 4000

StorageKind = Literal["vector", "halfvec"]
IndexKind = Literal["hnsw", "hnsw_bq", "none"]

_SLUG_RE = re.compile(r"[^a-z0-9]+")


@dataclass(frozen=True)
class ModelSpec:
    """A model as the user asks for it, before storage decisions are made."""

    slug: str
    model_ref: str
    dims: int
    provider: str = "ollama"
    normalized: bool = True
    # True only for models documented as Matryoshka-trained (e.g. Qwen3-Embedding).
    supports_mrl: bool = False


@dataclass(frozen=True)
class StoragePlan:
    """How a model's vectors will physically be stored and indexed."""

    stored_dims: int
    storage_kind: StorageKind
    index_kind: IndexKind
    # Set when stored_dims < dims, explaining the reduction.
    truncated_from: int | None = None

    @property
    def is_truncated(self) -> bool:
        return self.truncated_from is not None


def table_name_for(slug: str) -> str:
    """Derive the per-model table name.

    Constrained to ``^emb_[a-z0-9_]+$`` and matched by a CHECK constraint in
    ``sql/003_registry.sql``, because this identifier is interpolated into DDL
    and search SQL where bind parameters cannot be used.
    """
    normalized = _SLUG_RE.sub("_", slug.strip().lower()).strip("_")
    if not normalized:
        raise ValueError(f"model slug {slug!r} normalizes to an empty identifier")
    name = f"emb_{normalized}"
    # Postgres truncates identifiers at 63 bytes; truncating here keeps the
    # registry's table_name in agreement with what Postgres actually created.
    return name[:63].rstrip("_")


def plan_storage(dims: int, *, supports_mrl: bool = False) -> StoragePlan:
    """Choose storage type and index strategy for a model of width ``dims``."""
    if dims <= 0:
        raise ValueError(f"dims must be positive, got {dims}")

    if dims <= HNSW_MAX_VECTOR_DIMS:
        return StoragePlan(stored_dims=dims, storage_kind="vector", index_kind="hnsw")

    if dims <= HNSW_MAX_HALFVEC_DIMS:
        # Too wide for an indexed `vector`, but halfvec's ceiling covers it.
        # Half precision costs little for retrieval and halves index size.
        return StoragePlan(stored_dims=dims, storage_kind="halfvec", index_kind="hnsw")

    if supports_mrl:
        # Truncate to the halfvec ceiling; MRL guarantees the prefix is valid.
        return StoragePlan(
            stored_dims=HNSW_MAX_HALFVEC_DIMS,
            storage_kind="halfvec",
            index_kind="hnsw",
            truncated_from=dims,
        )

    # Cannot truncate safely and cannot index directly: keep full fidelity and
    # index a binary quantization, re-ranking exact cosine at query time.
    return StoragePlan(stored_dims=dims, storage_kind="vector", index_kind="hnsw_bq")


def column_type_sql(plan: StoragePlan) -> str:
    """DDL fragment for the embedding column."""
    return f"{plan.storage_kind}({plan.stored_dims})"


def index_ddl(table: str, plan: StoragePlan) -> str | None:
    """DDL for the vector index, or ``None`` when the model is unindexed."""
    if plan.index_kind == "none":
        return None

    if plan.index_kind == "hnsw":
        ops = "vector_cosine_ops" if plan.storage_kind == "vector" else "halfvec_cosine_ops"
        return (
            f"CREATE INDEX IF NOT EXISTS {table}_hnsw ON {table} "
            f"USING hnsw (embedding {ops}) WITH (m = 16, ef_construction = 64)"
        )

    # Binary quantization: index the quantized bits, not the vector itself.
    return (
        f"CREATE INDEX IF NOT EXISTS {table}_hnsw_bq ON {table} "
        f"USING hnsw ((binary_quantize(embedding)::bit({plan.stored_dims})) bit_hamming_ops)"
    )


def truncate_vector(values: list[float], plan: StoragePlan) -> list[float]:
    """Apply the plan's dimensional reduction to one embedding.

    Re-normalizes after truncation: a prefix of a unit vector is not itself unit
    length, and cosine distance in pgvector does not normalize for you.
    """
    if len(values) == plan.stored_dims:
        return values
    if len(values) < plan.stored_dims:
        raise ValueError(
            f"embedding has {len(values)} dims, expected at least {plan.stored_dims}"
        )

    head = values[: plan.stored_dims]
    norm = sum(v * v for v in head) ** 0.5
    if norm == 0.0:
        return head
    return [v / norm for v in head]


# Known models, so `garage register-model bge-m3` does not require the user to
# look up widths. Anything absent can be registered with an explicit --dims.
KNOWN_MODELS: dict[str, ModelSpec] = {
    "nomic-embed-text": ModelSpec(
        slug="nomic-embed-text", model_ref="nomic-embed-text", dims=768
    ),
    "bge-m3": ModelSpec(slug="bge-m3", model_ref="bge-m3", dims=1024),
    "mxbai-embed-large": ModelSpec(
        slug="mxbai-embed-large", model_ref="mxbai-embed-large", dims=1024
    ),
    "embeddinggemma": ModelSpec(slug="embeddinggemma", model_ref="embeddinggemma", dims=768),
    "snowflake-arctic-embed2": ModelSpec(
        slug="snowflake-arctic-embed2", model_ref="snowflake-arctic-embed2", dims=1024
    ),
    # Qwen3 embedding family is Matryoshka-trained, so truncation is safe.
    "qwen3-embedding-0.6b": ModelSpec(
        slug="qwen3-embedding-0.6b",
        model_ref="qwen3-embedding:0.6b",
        dims=1024,
        supports_mrl=True,
    ),
    "qwen3-embedding-4b": ModelSpec(
        slug="qwen3-embedding-4b",
        model_ref="qwen3-embedding:4b",
        dims=2560,
        supports_mrl=True,
    ),
    "qwen3-embedding-8b": ModelSpec(
        slug="qwen3-embedding-8b",
        model_ref="qwen3-embedding:8b",
        dims=4096,
        supports_mrl=True,
    ),
}
