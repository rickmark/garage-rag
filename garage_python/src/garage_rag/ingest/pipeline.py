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

from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from garage_rag.attribute.resolver import (
    Attribution,
    SelfIdentity,
    ensure_self_author,
    get_or_create_author,
    resolve,
)
from garage_rag.config import get_settings
from garage_rag.db.models import (
    Chunk,
    CorpusClass,
    Document,
    DocumentAuthor,
    IngestRun,
    IngestSeen,
    IngestState,
    Source,
)
from garage_rag.extract.base import ExtractionError, ExtractResult, file_sha256, sha256_text
from garage_rag.extract.dispatch import extract
from garage_rag.extract.placeholder import PlaceholderFile
from garage_rag.extract.quality import assess
from garage_rag.ingest.chunking import TextChunk, chunk_text
from garage_rag.ingest.classify import classify
from garage_rag.ingest.gateway import (
    AuthorPayload,
    ChunkPayload,
    IngestStorageGateway,
    SourceContext,
    SqlAlchemyIngestStorageGateway,
    get_storage_gateway,
)
from garage_rag.ingest.materialize import MaterializationBudget, ensure_local
from garage_rag.ingest.scanner import scan_source
from garage_rag.ingest.walker import Candidate, WalkStats, default_exclude_prefixes, walk

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
    total_items: int = 0
    item_type: str = "items"
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
    gateway_or_session: IngestStorageGateway | Session,
    source_or_context: SourceContext | Source,
    candidate: Candidate,
    *,
    self_identity: SelfIdentity,
    budget: MaterializationBudget,
    counters: IngestCounters,
    force: bool = False,
) -> None:
    """Index a single file, replacing any previous version of it."""
    log.debug("Evaluating %s (size=%d bytes, placeholder=%s)", candidate.uri, candidate.size, candidate.placeholder)

    if isinstance(gateway_or_session, Session):
        session = gateway_or_session
        source = source_or_context
        # Legacy session path fallback if called with raw Session
        existing = (
            session.query(Document).filter_by(source_id=source.id, uri=candidate.uri).one_or_none()
        )
        if existing is not None and not force and not candidate.placeholder:
            same_size = existing.byte_size == candidate.size
            same_mtime = (
                existing.mtime is not None
                and abs((existing.mtime - candidate.mtime).total_seconds()) < 1.0
            )
            if same_size and same_mtime and existing.state == IngestState.OK:
                counters.skipped += 1
                return

        try:
            ensure_local(candidate.path, budget)
        except PlaceholderFile:
            counters.placeholders += 1
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
        if settings.reject_machine_generated:
            verdict = assess(result.text)
            if verdict.machine_generated:
                counters.rejected += 1
                if existing is not None:
                    session.delete(existing)
                return

        content_hash = sha256_text(result.text)
        try:
            raw_hash = file_sha256(candidate.path)
        except OSError:
            raw_hash = None

        chunks = chunk_text(result.text, result.kind, extension=candidate.path.suffix.lower())
        if not chunks:
            counters.note_error(f"{candidate.path.name}: produced no chunks")
            return

        truncated_chunks = 0
        if len(chunks) > settings.max_chunks_per_document:
            truncated_chunks = len(chunks) - settings.max_chunks_per_document
            chunks = chunks[: settings.max_chunks_per_document]
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
        written = _write_chunks(session, document, chunks)
        counters.chunks_written += written
        counters.indexed += 1
        return

    # Gateway execution path
    gateway = gateway_or_session
    source_ctx = source_or_context

    existing_stat = gateway.check_stat(source_ctx.slug, candidate.uri)

    # --- step 1: skip on unchanged stat, without opening the file -----------
    if existing_stat.exists and not force and not candidate.placeholder:
        same_size = existing_stat.byte_size == candidate.size
        same_mtime = (
            existing_stat.mtime > 0
            and abs(existing_stat.mtime - candidate.mtime.timestamp()) < 1.0
        )
        if same_size and same_mtime and existing_stat.state.upper() == "OK":
            log.debug("Skipped %s: stat matches existing document in DB", candidate.uri)
            counters.skipped += 1
            return

    # --- materialize if this is a cloud stub --------------------------------
    try:
        ensure_local(candidate.path, budget)
    except PlaceholderFile:
        log.info("Placeholder file detected for %s: recording as PLACEHOLDER in DB", candidate.uri)
        counters.placeholders += 1
        gateway.record_placeholder(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            candidate.mtime.timestamp(),
            candidate.path.stem,
            "not materialized",
        )
        return

    # --- step 2: extract ----------------------------------------------------
    log.debug("Extracting %s (allows_cloud=%s)", candidate.uri, bool(source_ctx.allow_cloud_enrichment))
    try:
        result = extract(
            candidate.path,
            source_allows_cloud=bool(source_ctx.allow_cloud_enrichment),
        )
        log.debug("Extraction succeeded for %s (%s, %d characters)", candidate.path.name, result.extractor, len(result.text))
    except (ExtractionError, OSError) as exc:
        counters.note_error(f"{candidate.path.name}: {exc}")
        log.warning("Extraction failed for %s: %s", candidate.uri, exc)
        gateway.record_extract_failed(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            str(exc),
        )
        return

    settings = get_settings()

    # Content-based backstop for machine output the path rules missed.
    if settings.reject_machine_generated:
        verdict = assess(result.text)
        if verdict.machine_generated:
            counters.rejected += 1
            log.info("Rejected machine-generated file %s: %s", candidate.path.name, verdict.reason_text)
            gateway.record_rejected(
                source_ctx.run_id,
                source_ctx.slug,
                candidate.uri,
            )
            return

    content_hash = sha256_text(result.text)
    try:
        raw_hash_bytes = file_sha256(candidate.path)
        raw_hash_hex = raw_hash_bytes.hex() if raw_hash_bytes else None
    except OSError:
        raw_hash_hex = None

    chunks = chunk_text(result.text, result.kind, extension=candidate.path.suffix.lower())
    if not chunks:
        log.warning("%s produced 0 chunks from %d characters", candidate.path.name, len(result.text))
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
        source_default=source_ctx.default_class,
        source_pins_class=source_ctx.default_class is CorpusClass.COMMUNICATION,
    )
    attribution = resolve(
        candidate.path,
        Path(source_ctx.root),
        source_default_trust=source_ctx.default_trust,
        author_hints=result.author_hints,
        self_identity=self_identity,
    )

    # --- step 3: content unchanged -> keep chunks, refresh metadata ---------
    if (
        existing_stat.exists
        and not force
        and existing_stat.content_sha256 == content_hash
        and existing_stat.chunker == signature
        and existing_stat.state.upper() == "OK"
    ):
        log.debug("Skipped %s: content hash %s unchanged, refreshing metadata", candidate.uri, content_hash[:8])
        gateway.refresh_metadata(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            candidate.size,
            candidate.mtime.timestamp(),
            raw_hash_hex or "",
            corpus_class.value if hasattr(corpus_class, "value") else str(corpus_class),
            attribution.trust.value if hasattr(attribution.trust, "value") else str(attribution.trust),
        )
        counters.skipped += 1
        return

    # --- step 4: replace ----------------------------------------------------
    meta = {
        **result.meta,
        **attribution.meta,
        "attribution": attribution.evidence,
        **({"truncated_chunks": truncated_chunks} if truncated_chunks else {}),
    }

    authors = [
        AuthorPayload(
            name=cand.name,
            role=cand.role.value if hasattr(cand.role, "value") else str(cand.role),
            confidence=cand.confidence,
            evidence=cand.evidence,
            identities=dict(cand.identity_pairs),
            is_self=self_identity.matches(name=cand.name, email=cand.email),
        )
        for cand in attribution.authors
        if cand.name
    ]

    chunk_payloads = [
        ChunkPayload(
            ord=chunk.ord,
            text=chunk.text,
            token_count=chunk.token_estimate,
            char_start=chunk.char_start,
            char_end=chunk.char_end,
            heading_path=chunk.heading_path,
            chunk_sha256=chunk.sha256.hex() if isinstance(chunk.sha256, bytes) else str(chunk.sha256),
            chunker=chunk.chunker,
        )
        for chunk in chunks
    ]

    written = gateway.replace_document(
        run_id=source_ctx.run_id,
        source_slug=source_ctx.slug,
        uri=candidate.uri,
        title=result.title,
        lang=result.lang,
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp(),
        source_sha256=raw_hash_hex,
        content_sha256=content_hash,
        extractor=result.extractor,
        extractor_version=result.extractor_version,
        chunker=signature,
        content=result.text,
        meta=meta,
        corpus_class=corpus_class.value if hasattr(corpus_class, "value") else str(corpus_class),
        trust_tier=attribution.trust.value if hasattr(attribution.trust, "value") else str(attribution.trust),
        authors=authors,
        chunks=chunk_payloads,
    )

    counters.chunks_written += written
    counters.indexed += 1
    log.info(
        "Indexed %s -> %d chunks (%s, %s, author=%s)",
        candidate.path.name,
        written,
        corpus_class.name,
        attribution.trust.name,
        attribution.authors[0].name if attribution.authors else "unknown",
    )


def ingest_source(
    session_factory=None,
    source_slug: str = "",
    *,
    gateway: IngestStorageGateway | None = None,
    grpc_client: Any | None = None,
    grpc_host: str | None = None,
    grpc_port: int | None = None,
    include_code: bool = False,
    limit: int | None = None,
    force: bool = False,
    progress=None,
    is_cancelled=None,
) -> tuple[IngestCounters, WalkStats, MaterializationBudget]:
    """Walk and index one source, recording coverage for reconciliation."""
    gw = get_storage_gateway(
        session_factory=session_factory,
        gateway=gateway,
        grpc_client=grpc_client,
        grpc_host=grpc_host,
        grpc_port=grpc_port,
    )

    counters = IngestCounters()
    walk_stats = WalkStats()
    budget = MaterializationBudget.from_settings()

    source_ctx = gw.begin_session(source_slug, include_code=include_code)
    root = Path(source_ctx.root)
    source_class = source_ctx.default_class
    run_id = source_ctx.run_id

    log.info(
        "Beginning ingest_source for %r (id=%s, root=%s, class=%s, include_code=%s, limit=%s, force=%s)",
        source_slug,
        source_ctx.source_id,
        root,
        source_class.name,
        include_code,
        limit,
        force,
    )

    self_identity = SelfIdentity.from_settings()
    prefixes = default_exclude_prefixes(source_class, root)
    completed = False

    # --- Step 0: Scan Phase ---
    log.info("Starting source scan for %r...", source_slug)
    scan_result = scan_source(source_ctx, include_code=include_code)
    counters.total_items = scan_result.item_count
    counters.item_type = scan_result.item_type
    log.info(
        "Source scan completed for %r in %.2fs: found %d %s",
        source_slug,
        scan_result.duration_seconds,
        scan_result.item_count,
        scan_result.item_type,
    )

    gw.persist_scan(source_slug, scan_result)

    def _call_progress(phase: str, current_item: str | None = None) -> None:
        if progress is None:
            return
        try:
            progress(
                counters,
                budget,
                total_items=counters.total_items,
                phase=phase,
                scan_result=scan_result,
                current_item=current_item,
            )
        except TypeError:
            try:
                progress(counters, budget, total_items=counters.total_items, phase=phase, current_item=current_item)
            except TypeError:
                try:
                    progress(counters, budget, total_items=counters.total_items, phase=phase)
                except TypeError:
                    progress(counters, budget)

    _call_progress(phase="scan")

    log.info("Starting file walk for %r (root=%s)", source_slug, root)
    try:
        for candidate in walk(
            root,
            include_code=include_code,
            exclude_prefixes=prefixes,
            stats=walk_stats,
        ):
            if is_cancelled is not None and is_cancelled():
                log.info("Ingest cancelled by user for source %s", source_slug)
                _call_progress(phase="cancelled", current_item=candidate.path.name)
                break

            counters.seen += 1
            try:
                ingest_one(
                    gw,
                    source_ctx,
                    candidate,
                    self_identity=self_identity,
                    budget=budget,
                    counters=counters,
                    force=force,
                )
            except Exception as exc:  # noqa: BLE001 - one file must not end the run
                counters.note_error(f"{candidate.path.name}: {exc}")
                log.warning("Ingest failed for %s: %s", candidate.path, exc, exc_info=True)

            _call_progress(phase="ingest", current_item=candidate.path.name)
            if limit is not None and counters.seen >= limit:
                log.info("Hit candidate limit (%d) for source %r", limit, source_slug)
                break
        else:
            # Only a walk that ran to exhaustion counts as full coverage.
            completed = True
    finally:
        gw.finalize_session(
            run_id=run_id,
            completed=completed and limit is None,
            seen=counters.seen,
            indexed=counters.indexed,
            skipped=counters.skipped,
            failed=counters.failed,
            placeholders=counters.placeholders,
            materialized=budget.files_done,
            materialized_bytes=budget.bytes_done,
            errors=counters.errors,
        )

        log.info(
            "Finished ingest for %r: total_items=%d, seen=%d, indexed=%d, skipped=%d, failed=%d, placeholders=%d, chunks=%d, errors=%d",
            source_slug,
            counters.total_items,
            counters.seen,
            counters.indexed,
            counters.skipped,
            counters.failed,
            counters.placeholders,
            counters.chunks_written,
            len(counters.errors),
        )

    return counters, walk_stats, budget
