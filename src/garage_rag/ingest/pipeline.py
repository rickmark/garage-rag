"""The ingest pipeline.

Idempotency contract, per document, each in its own transaction so a crash
leaves earlier documents committed and the current one untouched:

1. **stat only.** If a row exists whose ``mtime``, ``byte_size``, and
   ``source_sha256`` all match, skip -- without opening or parsing the file, and
   crucially without materializing a cloud placeholder.
2. **extract**, then hash the extracted text.
3. If ``content_sha256`` is unchanged *and* the chunker signature is unchanged,
   the chunks are still valid: refresh the stat fields, backfill any missing
   model embeddings, done.
4. Otherwise replace: upsert the document, delete its chunks (which cascades
   into every per-model embedding table), re-chunk, insert.

The two hashes are not redundant. ``source_sha256`` is over raw bytes and enables
step 1. ``content_sha256`` is over extracted text and drives step 3, so
upgrading an extractor correctly rebuilds chunks even though the file on disk
never changed.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import text as sql_text
from sqlalchemy.orm import Session

from ..attribute.resolver import (
    Attribution,
    SelfIdentity,
    ensure_self_author,
    get_or_create_author,
    resolve,
)
from ..config import get_settings
from ..db.models import (
    Chunk,
    CorpusClass,
    Document,
    DocumentAuthor,
    IngestRun,
    IngestState,
    Source,
)
from ..extract.base import ExtractionError, ExtractResult, file_sha256, sha256_text
from ..extract.dispatch import extract
from ..extract.placeholder import PlaceholderFile
from ..extract.quality import assess
from .chunking import TextChunk, chunk_text
from .classify import classify
from .materialize import MaterializationBudget, ensure_local
from .walker import Candidate, WalkStats, default_exclude_prefixes, walk

log = logging.getLogger(__name__)


@dataclass
class IngestCounters:
    seen: int = 0
    indexed: int = 0
    skipped: int = 0
    failed: int = 0
    placeholders: int = 0
    rejected: int = 0
    chunks_written: int = 0
    errors: list[str] = field(default_factory=list)

    def note_error(self, message: str) -> None:
        self.failed += 1
        if len(self.errors) < 50:
            self.errors.append(message)


def _chunker_signature(result: ExtractResult, chunks: list[TextChunk]) -> str:
    """Identifies the chunking configuration that produced these chunks.

    Stored so a change in chunk size or strategy triggers a rebuild the same way
    a content change does.
    """
    label = chunks[0].chunker if chunks else "none"
    return f"{result.kind}:{label}"


def _apply_authors(
    session: Session,
    document: Document,
    attribution: Attribution,
    self_identity: SelfIdentity,
) -> None:
    """Replace a document's authorship rows."""
    session.query(DocumentAuthor).filter_by(document_id=document.id).delete()

    seen: set[tuple[int, str]] = set()
    for candidate in attribution.authors:
        if not candidate.name:
            continue
        is_self = self_identity.matches(name=candidate.name, email=candidate.email)
        author = get_or_create_author(
            session,
            candidate.name,
            identities=candidate.identity_pairs,
            is_self=is_self,
        )
        key = (author.id, str(candidate.role))
        if key in seen:
            continue
        seen.add(key)
        session.add(
            DocumentAuthor(
                document_id=document.id,
                author_id=author.id,
                role=candidate.role,
                confidence=candidate.confidence,
                evidence=candidate.evidence,
            )
        )


def _write_chunks(session: Session, document: Document, chunks: list[TextChunk]) -> int:
    """Replace a document's chunks.

    The delete cascades into every per-model embedding table, so stale vectors
    cannot outlive the text they were derived from.
    """
    session.query(Chunk).filter_by(document_id=document.id).delete()
    session.flush()

    for chunk in chunks:
        session.add(
            Chunk(
                document_id=document.id,
                ord=chunk.ord,
                text=chunk.text,
                token_count=chunk.token_estimate,
                char_start=chunk.char_start,
                char_end=chunk.char_end,
                heading_path=chunk.heading_path,
                chunk_sha256=chunk.sha256,
                chunker=chunk.chunker,
            )
        )
    return len(chunks)


def ingest_one(
    session: Session,
    source: Source,
    candidate: Candidate,
    *,
    self_identity: SelfIdentity,
    budget: MaterializationBudget,
    counters: IngestCounters,
    force: bool = False,
) -> None:
    """Index a single file, replacing any previous version of it."""
    existing = (
        session.query(Document)
        .filter_by(source_id=source.id, uri=candidate.uri)
        .one_or_none()
    )

    # --- step 1: skip on unchanged stat, without opening the file -----------
    if existing is not None and not force and not candidate.placeholder:
        same_size = existing.byte_size == candidate.size
        same_mtime = existing.mtime is not None and abs(
            (existing.mtime - candidate.mtime).total_seconds()
        ) < 1.0
        if same_size and same_mtime and existing.state == IngestState.OK:
            counters.skipped += 1
            return

    # --- materialize if this is a cloud stub --------------------------------
    try:
        ensure_local(candidate.path, budget)
    except PlaceholderFile:
        counters.placeholders += 1
        # Recorded rather than ignored, so `garage stats` can show what is
        # pending download instead of it silently missing from the corpus.
        if existing is None:
            session.add(
                Document(
                    source_id=source.id,
                    uri=candidate.uri,
                    corpus_class=source.default_class,
                    trust_tier=source.default_trust,
                    title=candidate.path.stem,
                    byte_size=0,
                    mtime=candidate.mtime,
                    content_sha256=sha256_text(""),
                    extractor="none",
                    state=IngestState.PLACEHOLDER,
                    error="not materialized",
                )
            )
        elif existing.state != IngestState.PLACEHOLDER:
            existing.state = IngestState.PLACEHOLDER
            existing.error = "not materialized"
        return

    # --- step 2: extract ----------------------------------------------------
    try:
        result = extract(
            candidate.path,
            source_allows_cloud=bool(source.allow_cloud_enrichment),
        )
    except (ExtractionError, OSError) as exc:
        counters.note_error(f"{candidate.path.name}: {exc}")
        if existing is not None:
            existing.state = IngestState.EXTRACT_FAILED
            existing.error = str(exc)[:2000]
        return

    settings = get_settings()

    # Content-based backstop for machine output the path rules missed.
    if settings.reject_machine_generated:
        verdict = assess(result.text)
        if verdict.machine_generated:
            counters.rejected += 1
            log.debug("rejected %s: %s", candidate.path.name, verdict.reason_text)
            if existing is not None:
                # Previously indexed and now judged machine-generated: drop it,
                # which cascades its chunks and vectors away.
                session.delete(existing)
            return

    content_hash = sha256_text(result.text)
    try:
        raw_hash = file_sha256(candidate.path)
    except OSError:
        raw_hash = None

    chunks = chunk_text(
        result.text, result.kind, extension=candidate.path.suffix.lower()
    )
    if not chunks:
        counters.note_error(f"{candidate.path.name}: produced no chunks")
        return

    # Final safety net: no single document may dominate the index.
    truncated_chunks = 0
    if len(chunks) > settings.max_chunks_per_document:
        truncated_chunks = len(chunks) - settings.max_chunks_per_document
        chunks = chunks[: settings.max_chunks_per_document]
        log.info(
            "%s produced %d chunks; truncated to %d",
            candidate.path.name,
            len(chunks) + truncated_chunks,
            settings.max_chunks_per_document,
        )
    signature = _chunker_signature(result, chunks)

    corpus_class = classify(
        candidate.path,
        result.kind,
        source_default=source.default_class,
        source_pins_class=source.default_class is CorpusClass.COMMUNICATION,
    )
    attribution = resolve(
        candidate.path,
        Path(source.root),
        source_default_trust=source.default_trust,
        author_hints=result.author_hints,
        self_identity=self_identity,
    )

    # --- step 3: content unchanged -> keep chunks, refresh metadata ---------
    if (
        existing is not None
        and not force
        and existing.content_sha256 == content_hash
        and existing.chunker == signature
        and existing.state == IngestState.OK
    ):
        existing.byte_size = candidate.size
        existing.mtime = candidate.mtime
        existing.source_sha256 = raw_hash
        existing.corpus_class = corpus_class
        existing.trust_tier = attribution.trust
        counters.skipped += 1
        return

    # --- step 4: replace ----------------------------------------------------
    document = existing
    if document is None:
        document = Document(source_id=source.id, uri=candidate.uri)
        session.add(document)

    document.corpus_class = corpus_class
    document.trust_tier = attribution.trust
    document.title = result.title
    document.mime = None
    document.lang = result.lang
    document.byte_size = candidate.size
    document.mtime = candidate.mtime
    document.source_sha256 = raw_hash
    document.content_sha256 = content_hash
    document.extractor = result.extractor
    document.extractor_version = result.extractor_version
    document.chunker = signature
    document.content = result.text
    document.meta = {
        **result.meta,
        **attribution.meta,
        "attribution": attribution.evidence,
        **({"truncated_chunks": truncated_chunks} if truncated_chunks else {}),
    }
    document.state = IngestState.OK
    document.error = None
    document.ingested_at = datetime.now(tz=UTC)
    session.flush()

    _apply_authors(session, document, attribution, self_identity)
    counters.chunks_written += _write_chunks(session, document, chunks)
    counters.indexed += 1


def ingest_source(
    session_factory,
    source_slug: str,
    *,
    include_code: bool = False,
    limit: int | None = None,
    force: bool = False,
    progress=None,
) -> tuple[IngestCounters, WalkStats, MaterializationBudget]:
    """Walk and index one source, recording coverage for reconciliation."""
    counters = IngestCounters()
    walk_stats = WalkStats()
    budget = MaterializationBudget.from_settings()

    with session_factory() as bootstrap:
        source = bootstrap.query(Source).filter_by(slug=source_slug).one_or_none()
        if source is None:
            raise LookupError(f"no such source: {source_slug}")
        source_id = source.id
        root = Path(source.root)
        source_class = source.default_class
        ensure_self_author(bootstrap)
        run = IngestRun(source_id=source_id)
        bootstrap.add(run)
        bootstrap.flush()
        run_id = run.id
        bootstrap.commit()

    self_identity = SelfIdentity.from_settings()
    prefixes = default_exclude_prefixes(source_class, root)
    completed = False

    try:
        for candidate in walk(
            root,
            include_code=include_code,
            exclude_prefixes=prefixes,
            stats=walk_stats,
        ):
            counters.seen += 1
            # One transaction per document: a failure isolates to its own file.
            with session_factory() as session:
                src = session.get(Source, source_id)
                try:
                    ingest_one(
                        session,
                        src,
                        candidate,
                        self_identity=self_identity,
                        budget=budget,
                        counters=counters,
                        force=force,
                    )
                    session.execute(
                        sql_text(
                            "INSERT INTO ingest_seen (run_id, uri) VALUES (:r, :u) "
                            "ON CONFLICT DO NOTHING"
                        ),
                        {"r": run_id, "u": candidate.uri},
                    )
                    session.commit()
                except Exception as exc:  # noqa: BLE001 - one file must not end the run
                    session.rollback()
                    counters.note_error(f"{candidate.path.name}: {exc}")
                    log.debug("ingest failed for %s", candidate.path, exc_info=True)

            if progress is not None:
                progress(counters, budget)
            if limit is not None and counters.seen >= limit:
                break
        else:
            # Only a walk that ran to exhaustion counts as full coverage.
            completed = True
    finally:
        with session_factory() as session:
            run = session.get(IngestRun, run_id)
            if run is not None:
                run.finished_at = datetime.now(tz=UTC)
                run.completed = completed and limit is None
                run.seen_count = counters.seen
                run.indexed_count = counters.indexed
                run.skipped_count = counters.skipped
                run.failed_count = counters.failed
                run.placeholder_count = counters.placeholders
                run.materialized_count = budget.files_done
                run.materialized_bytes = budget.bytes_done
                if counters.errors:
                    run.error = "; ".join(counters.errors[:5])[:4000]
            session.commit()

    return counters, walk_stats, budget
