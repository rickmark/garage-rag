"""Removing documents whose source files are gone.

The dangerous part of deletion is not the delete, it is deciding that something
is missing. A source root that failed to mount, a permissions change, or an
interrupted walk all look exactly like "every file was deleted". Acting on that
would silently destroy the index.

So reconciliation trusts only a run that recorded **completed coverage**: a walk
that ran to exhaustion (one cut short by ``--limit`` or cancellation does not
count). Every URI it observed -- indexed, skipped or failed -- is recorded in
``ingest_seen``; anything in ``documents`` for that source but absent from the
latest completed run's observations is genuinely gone.

A sanity threshold guards the remaining case. If a completed run would delete
more than ``max_delete_fraction`` of a source, that is treated as suspicious and
refused unless explicitly forced -- losing a corpus to an unnoticed mount failure
is far worse than carrying stale rows until someone looks.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from sqlalchemy import func
from sqlalchemy.orm import Session

from garage_rag.db.models import Document, IngestRun, IngestSeen, Source

log = logging.getLogger(__name__)

# Refuse to delete more than this share of a source without --force.
DEFAULT_MAX_DELETE_FRACTION = 0.25


@dataclass
class ReconcileResult:
    source: str
    candidates: int = 0
    deleted: int = 0
    total_documents: int = 0
    refused: bool = False
    reason: str = ""

    @property
    def fraction(self) -> float:
        if not self.total_documents:
            return 0.0
        return self.candidates / self.total_documents


def latest_complete_run(session: Session, source_id: int) -> IngestRun | None:
    """Most recent run that covered the whole source."""
    return (
        session.query(IngestRun)
        .filter_by(source_id=source_id, completed=True)
        .order_by(IngestRun.started_at.desc())
        .first()
    )


def reconcile_source(
    session: Session,
    slug: str,
    *,
    dry_run: bool = True,
    force: bool = False,
    max_delete_fraction: float = DEFAULT_MAX_DELETE_FRACTION,
) -> ReconcileResult:
    """Delete documents absent from the latest complete scan of ``slug``."""
    source = session.query(Source).filter_by(slug=slug).one_or_none()
    if source is None:
        raise LookupError(f"no such source: {slug}")

    result = ReconcileResult(source=slug)
    run = latest_complete_run(session, source.id)
    if run is None:
        result.refused = True
        result.reason = (
            "no completed scan on record; run a full `garage ingest` (without "
            "--limit) before reconciling"
        )
        return result

    result.total_documents = (
        session.query(func.count(Document.id))
        .filter(Document.source_id == source.id)
        .scalar()
        or 0
    )

    ids = [
        row[0]
        for row in session.query(Document.id)
        .filter(
            Document.source_id == source.id,
            ~session.query(IngestSeen.uri)
            .filter(IngestSeen.run_id == run.id, IngestSeen.uri == Document.uri)
            .exists(),
        )
        .all()
    ]
    result.candidates = len(ids)

    if not ids:
        return result

    if not force and result.fraction > max_delete_fraction:
        result.refused = True
        result.reason = (
            f"would delete {result.candidates:,} of {result.total_documents:,} documents "
            f"({result.fraction:.0%} > {max_delete_fraction:.0%}); if the source really "
            "shrank that much, re-run with --force"
        )
        return result

    if dry_run:
        return result

    # Cascades through chunks into every per-model embedding table.
    session.query(Document).filter(Document.id.in_(ids)).delete(synchronize_session=False)
    result.deleted = len(ids)
    log.info("reconcile %s: deleted %d documents", slug, result.deleted)
    return result

