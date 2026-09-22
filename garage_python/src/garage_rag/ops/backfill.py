"""Embedding backfill, reported as a stream of events."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal

from garage_rag.db.emb_tables import get_model, list_models
from garage_rag.db.engine import session_scope

BackfillPhase = Literal["complete", "skipped", "started", "progress", "finished"]


@dataclass
class BackfillEvent:
    """One step of a backfill run.

    ``complete``: nothing was pending. ``skipped``: the model could not be used
    (``message`` says why). ``started``/``progress``/``finished`` bracket the
    embedding of one model's pending chunks.
    """

    model: str
    phase: BackfillPhase
    total: int = 0
    embedded: int = 0
    failed: int = 0
    batches: int = 0
    message: str = ""

    @property
    def remaining(self) -> int:
        return max(0, self.total - self.embedded - self.failed)


def backfill(
    model: str | None = None,
    *,
    batch_size: int | None = None,
    limit: int | None = None,
    verify: bool = True,
    on_event: Callable[[BackfillEvent], None],
) -> list[BackfillEvent]:
    """Embed the chunks each model (or just ``model``) has no vectors for.

    Pure insert, so safe to re-run and to interrupt. Every step is passed to
    ``on_event``; the ``finished``/``complete``/``skipped`` event of each model is
    also returned. Raises LookupError for an unknown model or when none exist.
    """
    from garage_rag.embed.ollama import EmbeddingError, backfill_model, count_pending, verify_model_dims

    outcomes: list[BackfillEvent] = []

    def emit(event: BackfillEvent) -> None:
        on_event(event)
        if event.phase in ("complete", "skipped", "finished"):
            outcomes.append(event)

    with session_scope() as session:
        targets = [get_model(session, model)] if model and model != "*" else list_models(session)
        if not targets:
            raise LookupError("no models registered")

        for row in targets:
            pending = count_pending(session, row)
            if pending == 0:
                emit(BackfillEvent(row.slug, "complete", message=f"{row.slug}: already complete"))
                continue

            if verify:
                try:
                    ok, actual = verify_model_dims(row)
                except EmbeddingError as exc:
                    emit(BackfillEvent(row.slug, "skipped", total=pending, message=f"{row.slug}: {exc}"))
                    continue
                if not ok:
                    # Every insert would fail the column type check; stop now rather
                    # than after an hour of work.
                    emit(
                        BackfillEvent(
                            row.slug,
                            "skipped",
                            total=pending,
                            message=(
                                f"{row.slug}: registered {row.dims} dims but the model emits {actual}. "
                                f"Re-register with --dims {actual}."
                            ),
                        )
                    )
                    continue

            emit(BackfillEvent(row.slug, "started", total=pending, message=f"{row.slug}: embedding {pending:,} chunks"))

            def on_progress(state, slug: str = row.slug) -> None:
                emit(
                    BackfillEvent(
                        slug,
                        "progress",
                        total=state.total,
                        embedded=state.embedded,
                        failed=state.failed,
                        batches=state.batches,
                        message=f"{slug}: {state.embedded:,}/{state.total:,} ({state.batches} batches)",
                    )
                )

            state = backfill_model(session, row, batch_size=batch_size, limit=limit, progress=on_progress)
            summary = f"{row.slug}: embedded {state.embedded:,}"
            if state.failed:
                summary += f", failed {state.failed:,}"
            if state.remaining:
                summary += f", remaining {state.remaining:,}"
            emit(
                BackfillEvent(
                    row.slug,
                    "finished",
                    total=state.total,
                    embedded=state.embedded,
                    failed=state.failed,
                    batches=state.batches,
                    message=summary,
                )
            )
    return outcomes
