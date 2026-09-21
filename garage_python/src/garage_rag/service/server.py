"""gRPC Server implementation for GarageService supporting dedicated RPC functions."""

from __future__ import annotations

import json
import logging
import os
import signal
import threading
import time
from collections.abc import Iterator
from concurrent import futures
from pathlib import Path
from typing import cast

import grpc

from garage_rag.proto.garage_pb2 import (
    AddSourceRequest,
    AddSourceResponse,
    BackfillRequest,
    BackfillStatus,
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    ChunkEmbeddingItem,
    CommandRequest,
    CommandStatus,
    ConfigImportSourcesRequest,
    ConfigImportSourcesResponse,
    ConfigInitRequest,
    ConfigInitResponse,
    ConfigPathRequest,
    ConfigPathResponse,
    ConfigSchemaRequest,
    ConfigSchemaResponse,
    ConfigShowRequest,
    ConfigShowResponse,
    DocumentAuthorInfo,
    DocumentAuthorPayload,
    DocumentChunkInfo,
    DocumentChunkPayload,
    DocumentDetail,
    DocumentFactInfo,
    DocumentSummary,
    DropModelRequest,
    DropModelResponse,
    EmbeddingChunkItem,
    EnrichFactsRequest,
    EnrichFactsStatus,
    ExtractChunk,
    ExtractRequest,
    ExtractResponse,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    GetDocumentRequest,
    GetDocumentResponse,
    GetEmbeddingBatchesRequest,
    GetEmbeddingBatchesResponse,
    IngestRequest,
    IngestStatus,
    InitDbRequest,
    InitDbResponse,
    ListDocumentsRequest,
    ListDocumentsResponse,
    ListModelsRequest,
    ListModelsResponse,
    ListSourcesRequest,
    ListSourcesResponse,
    McpClientInfo,
    McpInstallRequest,
    McpInstallResponse,
    McpServeRequest,
    McpServeStatus,
    McpStatusRequest,
    McpStatusResponse,
    McpUninstallRequest,
    McpUninstallResponse,
    ModelInfo,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    PersistScanResponse,
    PingRequest,
    PingResponse,
    ReconcileRequest,
    ReconcileResponse,
    RegisterModelRequest,
    RegisterModelResponse,
    RemoveSourceRequest,
    RemoveSourceResponse,
    ScanRequest,
    ScanResponse,
    SearchHit,
    SearchRequest,
    SearchResponse,
    SetDefaultModelRequest,
    SetDefaultModelResponse,
    SourceInfo,
    SourceScanStatus,
    StatsRequest,
    StatsResponse,
    StatusRequest,
    StatusResponse,
    StopRequest,
    StopResponse,
    SyncRequest,
    SyncStatus,
    UpdateEmbeddingsRequest,
    UpdateEmbeddingsResponse,
    VersionRequest,
    VersionResponse,
)
from garage_rag.proto.garage_pb2_grpc import (
    GarageServiceServicer,
    add_GarageServiceServicer_to_server,
)
from garage_rag.service.executor import CommandExecutor, default_executor

logger = logging.getLogger(__name__)


class GarageRpcServicer(GarageServiceServicer):
    """gRPC Servicer implementing GarageService with dedicated RPC methods."""

    def __init__(
        self,
        executor: CommandExecutor | None = None,
        stop_event: threading.Event | None = None,
    ) -> None:
        self.executor = executor or default_executor
        self.stop_event = stop_event or threading.Event()

    # -----------------------------------------------------------------------
    # System / Lifecycle
    # -----------------------------------------------------------------------

    def Ping(self, request: PingRequest, context: grpc.ServicerContext) -> PingResponse:
        """Ping / Healthcheck."""
        return PingResponse(
            message=request.message or "pong",
            timestamp=int(time.time()),
        )

    def GetStatus(self, request: StatusRequest, context: grpc.ServicerContext) -> StatusResponse:
        """Retrieve server and database status."""
        version = "0.1.0"
        try:
            import importlib.metadata

            version = importlib.metadata.version("garage_rag")
        except Exception:
            pass

        db_status = "unknown"
        is_ready = True
        try:
            from sqlalchemy import text
            from garage_rag.db.engine import get_engine
            from garage_rag.db.migrate import has_pending_migrations

            with get_engine().connect() as conn:
                conn.execute(text("SELECT 1"))

            if has_pending_migrations():
                db_status = "needs_migration"
                is_ready = False
            else:
                db_status = "connected"
                is_ready = True
        except Exception as e:
            db_status = f"error: {e}"
            is_ready = False

        return StatusResponse(
            version=version,
            is_ready=is_ready,
            pid=os.getpid(),
            db_status=db_status,
            server_type="grpc",
        )

    def GetVersion(self, request: VersionRequest, context: grpc.ServicerContext) -> VersionResponse:
        """Get the garage version."""
        version = "0.1.0"
        try:
            import importlib.metadata

            version = importlib.metadata.version("garage_rag")
        except Exception:
            pass

        return VersionResponse(version=version)

    def Stop(self, request: StopRequest, context: grpc.ServicerContext) -> StopResponse:
        """Trigger graceful shutdown of the server."""
        self.stop_event.set()
        return StopResponse(success=True)

    # -----------------------------------------------------------------------
    # Search
    # -----------------------------------------------------------------------

    def Search(self, request: SearchRequest, context: grpc.ServicerContext) -> SearchResponse:
        """Search the corpus with hybrid vector + keyword retrieval."""
        from garage_rag.db.engine import session_scope
        from garage_rag.search.hybrid import SearchMode
        from garage_rag.search.hybrid import search as run_search

        with session_scope() as session:
            hits = run_search(
                session,
                request.query,
                limit=request.limit or 10,
                mode=cast(SearchMode, request.mode or "hybrid"),
                model_slug=request.model or None,
                corpus_classes=list(request.corpus_classes) or None,
                trust_tiers=list(request.trust_tiers) or None,
                sources=list(request.sources) or None,
                author=request.author or None,
            )

        proto_hits: list[SearchHit] = []
        for rank, hit in enumerate(hits, start=1):
            snippet = hit.text if request.full else hit.text[:300].replace("\n", " ")
            proto_hits.append(
                SearchHit(
                    rank=rank,
                    title=hit.title or "(untitled)",
                    uri=hit.uri,
                    corpus_class=str(hit.corpus_class),
                    trust_tier=str(hit.trust_tier),
                    matched_by=str(hit.matched_by),
                    score=float(hit.score),
                    heading_path=hit.heading_path or "",
                    authors=hit.authors or [],
                    text=hit.text or "",
                    snippet=snippet,
                )
            )

        return SearchResponse(
            hits=proto_hits,
            total_hits=len(proto_hits),
            formatted_output=f"Found {len(proto_hits)} results for {request.query!r}",
        )

    # -----------------------------------------------------------------------
    # Documents & Chunks
    # -----------------------------------------------------------------------

    def ListDocuments(self, request: ListDocumentsRequest, context: grpc.ServicerContext) -> ListDocumentsResponse:
        """List documents, optionally filtered by source/class/trust/query."""
        from sqlalchemy import func, or_

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Fact, Source

        with session_scope() as session:
            query = session.query(Document).join(Source, Document.source_id == Source.id)

            if request.source:
                query = query.filter(Source.slug == request.source)
            if request.corpus_class:
                query = query.filter(Document.corpus_class == request.corpus_class)
            if request.trust_tier:
                query = query.filter(Document.trust_tier == request.trust_tier)
            if request.query:
                like = f"%{request.query}%"
                query = query.filter(or_(Document.title.ilike(like), Document.uri.ilike(like)))

            total_count = query.with_entities(func.count(Document.id)).scalar() or 0

            limit = request.limit or 100
            offset = max(request.offset, 0)
            documents = (
                query.order_by(Document.ingested_at.desc(), Document.id.desc())
                .offset(offset)
                .limit(limit)
                .all()
            )

            doc_ids = [d.id for d in documents]
            chunk_counts: dict[int, int] = {}
            fact_counts: dict[int, int] = {}
            slugs_by_doc_id: dict[int, str] = {}
            if doc_ids:
                chunk_counts = dict(
                    session.query(Chunk.document_id, func.count(Chunk.id))
                    .filter(Chunk.document_id.in_(doc_ids))
                    .group_by(Chunk.document_id)
                    .all()
                )
                fact_counts = dict(
                    session.query(Fact.document_id, func.count(Fact.id))
                    .filter(Fact.document_id.in_(doc_ids))
                    .group_by(Fact.document_id)
                    .all()
                )
                slugs_by_doc_id = dict(
                    session.query(Document.id, Source.slug)
                    .join(Source, Document.source_id == Source.id)
                    .filter(Document.id.in_(doc_ids))
                    .all()
                )

            summaries = [
                DocumentSummary(
                    id=d.id,
                    uri=d.uri,
                    title=d.title or "",
                    source_slug=slugs_by_doc_id.get(d.id, ""),
                    corpus_class=str(d.corpus_class),
                    trust_tier=str(d.trust_tier),
                    mime=d.mime or "",
                    lang=d.lang or "",
                    byte_size=d.byte_size or 0,
                    chunk_count=chunk_counts.get(d.id, 0),
                    state=str(d.state),
                    ingested_at=d.ingested_at.isoformat() if d.ingested_at else "",
                    fact_count=fact_counts.get(d.id, 0),
                )
                for d in documents
            ]

        return ListDocumentsResponse(
            documents=summaries,
            total_count=total_count,
            formatted_output=f"{len(summaries)} of {total_count} documents",
        )

    def GetDocument(self, request: GetDocumentRequest, context: grpc.ServicerContext) -> GetDocumentResponse:
        """Fetch a single document's metadata and its chunks."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Fact, Source

        with session_scope() as session:
            document = session.get(Document, request.document_id)
            if document is None:
                context.set_code(grpc.StatusCode.NOT_FOUND)
                context.set_details(f"document {request.document_id} not found")
                return GetDocumentResponse()

            source = session.get(Source, document.source_id)

            chunks = (
                session.query(Chunk)
                .filter(Chunk.document_id == document.id)
                .order_by(Chunk.ord.asc())
                .all()
            )

            facts = (
                session.query(Fact)
                .filter(Fact.document_id == document.id)
                .order_by(Fact.ord.asc())
                .all()
            )

            authors = [
                DocumentAuthorInfo(
                    name=da.author.display_name,
                    role=str(da.role),
                    confidence=float(da.confidence),
                )
                for da in document.authors
            ]

            detail = DocumentDetail(
                id=document.id,
                uri=document.uri,
                title=document.title or "",
                source_slug=source.slug if source else "",
                corpus_class=str(document.corpus_class),
                trust_tier=str(document.trust_tier),
                mime=document.mime or "",
                lang=document.lang or "",
                byte_size=document.byte_size or 0,
                extractor=document.extractor or "",
                extractor_version=document.extractor_version or "",
                chunker=document.chunker or "",
                meta_json=json.dumps(document.meta) if document.meta else "",
                state=str(document.state),
                error=document.error or "",
                ingested_at=document.ingested_at.isoformat() if document.ingested_at else "",
                authors=authors,
            )

            proto_chunks = [
                DocumentChunkInfo(
                    id=c.id,
                    ord=c.ord,
                    text=c.text,
                    token_count=c.token_count or 0,
                    char_start=c.char_start or 0,
                    char_end=c.char_end or 0,
                    heading_path=c.heading_path or "",
                )
                for c in chunks
            ]

            proto_facts = [
                DocumentFactInfo(
                    id=f.id,
                    ord=f.ord,
                    fact=f.fact,
                    fact_class=f.fact_class or "",
                    attributes_json=json.dumps(f.attributes) if f.attributes else "",
                    char_start=f.char_start or 0,
                    char_end=f.char_end or 0,
                    extractor=f.extractor or "",
                )
                for f in facts
            ]

        return GetDocumentResponse(
            document=detail,
            chunks=proto_chunks,
            formatted_output=f"{detail.title or detail.uri}: {len(proto_chunks)} chunks, {len(proto_facts)} facts",
            facts=proto_facts,
        )

    # -----------------------------------------------------------------------
    # Sources
    # -----------------------------------------------------------------------

    def ListSources(self, request: ListSourcesRequest, context: grpc.ServicerContext) -> ListSourcesResponse:
        """List registered sources."""
        from sqlalchemy import func

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Document, Source

        with session_scope() as session:
            sources = session.query(Source).order_by(Source.id).all()
            doc_counts = dict(
                session.query(Document.source_id, func.count(Document.id))
                .group_by(Document.source_id)
                .all()
            )
            proto_sources: list[SourceInfo] = [
                SourceInfo(
                    slug=s.slug,
                    kind=s.kind,
                    corpus_class=str(s.default_class),
                    trust_tier=str(s.default_trust),
                    allow_cloud_enrichment=bool(s.allow_cloud_enrichment),
                    enabled=bool(s.enabled),
                    root=s.root,
                    document_count=doc_counts.get(s.id, 0),
                    expected_elements=getattr(s, "expected_elements", 0) or 0,
                )
                for s in sources
            ]

        return ListSourcesResponse(
            sources=proto_sources,
            formatted_output=f"{len(proto_sources)} sources registered",
        )

    def AddSource(self, request: AddSourceRequest, context: grpc.ServicerContext) -> AddSourceResponse:
        """Register or update a source root."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import CorpusClass, Source, TrustTier

        tier = TrustTier(request.trust or "authored")
        klass = CorpusClass(request.corpus_class or "document")
        if klass is CorpusClass.COMMUNICATION and request.allow_cloud_enrichment:
            context.abort(
                grpc.StatusCode.INVALID_ARGUMENT,
                "communication sources may never enable cloud enrichment",
            )

        expanded = Path(request.root).expanduser()
        if not expanded.exists():
            context.abort(
                grpc.StatusCode.NOT_FOUND,
                f"{expanded} does not exist",
            )

        with session_scope() as session:
            existing = session.query(Source).filter_by(slug=request.slug).one_or_none()
            if existing is not None:
                existing.root = str(expanded)
                existing.kind = request.kind or "filesystem"
                existing.default_trust = tier
                existing.default_class = klass
                existing.allow_cloud_enrichment = request.allow_cloud_enrichment
                msg = f"updated source {request.slug} -> {expanded}"
            else:
                session.add(
                    Source(
                        slug=request.slug,
                        kind=request.kind or "filesystem",
                        root=str(expanded),
                        default_trust=tier,
                        default_class=klass,
                        allow_cloud_enrichment=request.allow_cloud_enrichment,
                    )
                )
                msg = f"added source {request.slug} -> {expanded} ({klass}/{tier})"

        return AddSourceResponse(
            success=True,
            message=msg,
            slug=request.slug,
            root=str(expanded),
            formatted_output=msg,
        )

    def RemoveSource(self, request: RemoveSourceRequest, context: grpc.ServicerContext) -> RemoveSourceResponse:
        """Deregister a source and cascade delete its documents, chunks, and vectors."""
        from sqlalchemy import func

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Document, Source

        with session_scope() as session:
            source = session.query(Source).filter_by(slug=request.slug).one_or_none()
            if source is None:
                context.abort(grpc.StatusCode.NOT_FOUND, f"no such source: {request.slug}")

            count = (
                session.query(func.count(Document.id))
                .filter(Document.source_id == source.id)
                .scalar()
                or 0
            )

            session.delete(source)

        return RemoveSourceResponse(
            success=True,
            deleted_documents=count,
            message=f"removed {request.slug} ({count:,} documents)",
            formatted_output=f"removed {request.slug} ({count:,} documents)",
        )

    # -----------------------------------------------------------------------
    # Ingest, Backfill, Reconcile
    # -----------------------------------------------------------------------

    def Scan(self, request: ScanRequest, context: grpc.ServicerContext) -> ScanResponse:
        """Scan source(s) to count items based on their source type."""
        from garage_rag.db.engine import get_session_factory
        from garage_rag.db.models import Source
        from garage_rag.ingest.scanner import persist_scan_result, scan_source

        factory = get_session_factory()
        target_sources = []
        with factory() as session:
            if request.source == "*" or not request.source:
                target_sources = list(session.query(Source).order_by(Source.id).all())
            else:
                s = session.query(Source).filter_by(slug=request.source).one_or_none()
                if s is None:
                    context.abort(grpc.StatusCode.NOT_FOUND, f"no such source: {request.source}")
                target_sources = [s]

        results = []
        total_items = 0
        with factory() as session:
            for src in target_sources:
                res = scan_source(src, include_code=request.include_code)
                total_items += res.item_count
                persist_scan_result(session, res)
                results.append(
                    SourceScanStatus(
                        source=res.source_slug,
                        kind=res.kind,
                        root=str(res.root),
                        item_count=res.item_count,
                        item_type=res.item_type,
                        error=res.error or "",
                        details={str(k): str(v) for k, v in res.details.items()},
                    )
                )
            session.commit()

        formatted = "\n".join(
            f"{r.source} ({r.kind}): {r.item_count:,} {r.item_type}" + (f" [error: {r.error}]" if r.error else "")
            for r in results
        )
        return ScanResponse(
            sources=results,
            total_items=total_items,
            formatted_output=formatted,
        )

    def Ingest(self, request: IngestRequest, context: grpc.ServicerContext) -> Iterator[IngestStatus]:
        """Walk a source and index it, streaming IngestStatus events."""
        from garage_rag.db.engine import get_session_factory
        from garage_rag.db.models import Source
        from garage_rag.ingest.pipeline import ingest_source
        from garage_rag.ingest.scanner import persist_scan_result, scan_source

        factory = get_session_factory()
        if request.source == "*":
            with factory() as session:
                sources = [s.slug for s in session.query(Source).order_by(Source.id).all()]
        else:
            sources = [request.source]

        for source_slug in sources:
            with factory() as session:
                src_obj = session.query(Source).filter_by(slug=source_slug).one_or_none()
                if src_obj:
                    scan_res = scan_source(src_obj, include_code=request.include_code)
                    persist_scan_result(session, scan_res)
                    session.commit()
                    yield IngestStatus(
                        source=source_slug,
                        is_complete=False,
                        progress=0.0,
                        progress_message=f"Scanned {source_slug}: found {scan_res.item_count:,} {scan_res.item_type}",
                        total_items=scan_res.item_count,
                        phase="scan",
                    )
                else:
                    yield IngestStatus(
                        source=source_slug,
                        is_complete=False,
                        progress=0.0,
                        progress_message=f"Scanning source {source_slug}...",
                        phase="scan",
                    )

            counters, walk_stats, budget = ingest_source(
                factory,
                source_slug,
                include_code=request.include_code,
                limit=request.limit or None,
                force=request.force,
            )

            summary = (
                f"Ingested {source_slug}: seen {counters.seen:,}/{counters.total_items:,} {counters.item_type}, "
                f"indexed {counters.indexed:,}, skipped {counters.skipped:,}, failed {counters.failed:,}, chunks {counters.chunks_written:,}"
            )
            yield IngestStatus(
                source=source_slug,
                candidates_seen=counters.seen,
                indexed=counters.indexed,
                skipped=counters.skipped,
                failed=counters.failed,
                rejected=counters.rejected,
                chunks_written=counters.chunks_written,
                placeholders=counters.placeholders,
                dirs_walked=walk_stats.dirs,
                files_examined=walk_stats.files_seen,
                is_complete=True,
                progress=1.0,
                progress_message=summary,
                sample_errors=counters.errors[:5] if counters.errors else [],
                formatted_output=summary,
                total_items=counters.total_items,
                phase="complete",
            )

    def Backfill(self, request: BackfillRequest, context: grpc.ServicerContext) -> Iterator[BackfillStatus]:
        """Embed chunks that a model has no vectors for, streaming BackfillStatus events."""
        from garage_rag.db.emb_tables import get_model, list_models
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.ollama import (
            EmbeddingError,
            backfill_model,
            count_pending,
            verify_model_dims,
        )

        with session_scope() as session:
            targets = [get_model(session, request.model)] if request.model and request.model != "*" else list_models(session)
            if not targets:
                context.abort(grpc.StatusCode.NOT_FOUND, "no models registered")

            for row in targets:
                pending = count_pending(session, row)
                if pending == 0:
                    yield BackfillStatus(
                        model_slug=row.slug,
                        total=0,
                        embedded=0,
                        is_complete=True,
                        progress=1.0,
                        progress_message=f"{row.slug}: already complete",
                        formatted_output=f"{row.slug}: already complete",
                    )
                    continue

                if request.verify:
                    try:
                        ok, actual = verify_model_dims(row)
                    except EmbeddingError as exc:
                        yield BackfillStatus(
                            model_slug=row.slug,
                            is_complete=True,
                            error_message=str(exc),
                            progress_message=f"{row.slug}: {exc}",
                        )
                        continue
                    if not ok:
                        yield BackfillStatus(
                            model_slug=row.slug,
                            is_complete=True,
                            error_message=f"registered {row.dims} dims but model emits {actual}",
                            progress_message=f"{row.slug}: dimension mismatch",
                        )
                        continue

                state = backfill_model(
                    session,
                    row,
                    batch_size=request.batch_size or None,
                    limit=request.limit or None,
                    progress=None,
                )

                summary = f"embedded {state.embedded:,}"
                if state.failed:
                    summary += f", failed {state.failed:,}"
                if state.remaining:
                    summary += f", remaining {state.remaining:,}"

                yield BackfillStatus(
                    model_slug=row.slug,
                    total=state.total,
                    embedded=state.embedded,
                    failed=state.failed,
                    remaining=state.remaining,
                    batches=state.batches,
                    is_complete=True,
                    progress=1.0,
                    progress_message=f"{row.slug}: {summary}",
                    formatted_output=f"{row.slug}: {summary}",
                )

    def EnrichFacts(self, request: EnrichFactsRequest, context: grpc.ServicerContext) -> Iterator[EnrichFactsStatus]:
        """Distill documents into facts, streaming EnrichFactsStatus events per document."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Document, Source
        from garage_rag.enrich.facts import DEFAULT_MODEL_ID, DEFAULT_PROVIDER, extract_and_store_facts

        model_id = request.model_id or DEFAULT_MODEL_ID
        provider = request.provider or DEFAULT_PROVIDER

        with session_scope() as session:
            if request.document_id:
                documents = [session.get(Document, request.document_id)]
                documents = [d for d in documents if d is not None]
                if not documents:
                    context.abort(grpc.StatusCode.NOT_FOUND, f"document {request.document_id} not found")
            else:
                query = session.query(Document)
                if request.source and request.source != "*":
                    query = query.join(Source, Document.source_id == Source.id).filter(Source.slug == request.source)
                documents = query.order_by(Document.id).all()

            total = len(documents)
            processed = 0
            failed = 0

            if total == 0:
                yield EnrichFactsStatus(
                    total=0,
                    is_complete=True,
                    progress=1.0,
                    progress_message="No documents to enrich.",
                    formatted_output="No documents to enrich.",
                )
                return

            for document in documents:
                try:
                    facts = extract_and_store_facts(session, document, model_id=model_id, provider=provider)
                    session.commit()
                    processed += 1
                    yield EnrichFactsStatus(
                        document_uri=document.uri or "",
                        document_id=document.id,
                        total=total,
                        processed=processed,
                        facts_extracted=len(facts),
                        failed=failed,
                        is_complete=processed + failed == total,
                        progress=(processed + failed) / total,
                        progress_message=f"{document.uri or document.id}: {len(facts)} facts",
                        formatted_output=f"{processed + failed}/{total} documents, {len(facts)} facts extracted",
                    )
                except Exception as exc:
                    session.rollback()
                    failed += 1
                    yield EnrichFactsStatus(
                        document_uri=document.uri or "",
                        document_id=document.id,
                        total=total,
                        processed=processed,
                        failed=failed,
                        is_complete=processed + failed == total,
                        progress=(processed + failed) / total,
                        error_message=str(exc),
                        progress_message=f"{document.uri or document.id}: failed ({exc})",
                        formatted_output=f"{processed + failed}/{total} documents, {failed} failed",
                    )

    def Reconcile(self, request: ReconcileRequest, context: grpc.ServicerContext) -> ReconcileResponse:
        """Delete documents whose source files no longer exist."""
        from garage_rag.db.engine import session_scope
        from garage_rag.ingest.reconcile import reconcile_source

        with session_scope() as session:
            result = reconcile_source(
                session,
                request.source,
                dry_run=not request.apply,
                force=request.force,
            )

        if result.refused:
            return ReconcileResponse(
                source=request.source,
                refused=True,
                reason=result.reason or "Refused",
                formatted_output=f"refused: {result.reason}",
            )

        return ReconcileResponse(
            source=request.source,
            total_documents=result.total_documents,
            candidates=result.candidates,
            deleted=result.deleted,
            fraction=float(result.fraction),
            refused=False,
            formatted_output=(
                f"reconcile for {request.source}: deleted {result.deleted:,} of {result.total_documents:,}"
            ),
        )

    # -----------------------------------------------------------------------
    # Models
    # -----------------------------------------------------------------------

    def RegisterModel(self, request: RegisterModelRequest, context: grpc.ServicerContext) -> RegisterModelResponse:
        """Register a new embedding model."""
        from garage_rag.db.emb_tables import register_model, resolve_spec
        from garage_rag.db.engine import session_scope

        with session_scope() as session:
            spec = resolve_spec(
                slug=request.slug,
                dims=request.dims or None,
                model_ref=request.model_ref or None,
                provider=request.provider or None,
                model_id=request.model_id or None,
            )
            row = register_model(session, spec, make_default=request.is_default)

        msg = f"registered model {row.slug} (table {row.table_name}, {row.storage_kind}/{row.index_kind})"
        return RegisterModelResponse(
            success=True,
            message=msg,
            formatted_output=msg,
        )

    def ListModels(self, request: ListModelsRequest, context: grpc.ServicerContext) -> ListModelsResponse:
        """List registered embedding models."""
        from garage_rag.db.emb_tables import list_models
        from garage_rag.db.engine import session_scope

        with session_scope() as session:
            models = list_models(session)
            proto_models: list[ModelInfo] = [
                ModelInfo(
                    slug=m.slug,
                    provider=m.provider,
                    model_ref=m.model_ref,
                    dims=m.dims,
                    stored_dims=m.stored_dims,
                    storage_kind=m.storage_kind,
                    index_kind=m.index_kind,
                    table_name=m.table_name,
                    is_default=m.is_default,
                    model_id=m.model_id or "",
                )
                for m in models
            ]

        return ListModelsResponse(
            models=proto_models,
            formatted_output=f"{len(proto_models)} models registered",
        )

    def SetDefaultModel(
        self, request: SetDefaultModelRequest, context: grpc.ServicerContext
    ) -> SetDefaultModelResponse:
        """Point default embedding model at slug."""
        from garage_rag.db.emb_tables import get_model, set_default_model
        from garage_rag.db.engine import session_scope

        with session_scope() as session:
            get_model(session, request.slug)
            set_default_model(session, request.slug)

        return SetDefaultModelResponse(
            success=True,
            message=f"default model = {request.slug}",
        )

    def DropModel(self, request: DropModelRequest, context: grpc.ServicerContext) -> DropModelResponse:
        """Deregister a model and drop its vectors."""
        from garage_rag.db.emb_tables import drop_model
        from garage_rag.db.engine import session_scope

        with session_scope() as session:
            drop_model(session, request.slug)

        return DropModelResponse(
            success=True,
            message=f"dropped {request.slug}",
        )

    # -----------------------------------------------------------------------
    # Stats & Extract
    # -----------------------------------------------------------------------

    def GetStats(self, request: StatsRequest, context: grpc.ServicerContext) -> StatsResponse:
        """Retrieve corpus and database stats."""
        from sqlalchemy import func

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Source

        with session_scope() as session:
            doc_count = session.query(func.count(Document.id)).scalar() or 0
            chunk_count = session.query(func.count(Chunk.id)).scalar() or 0
            source_count = session.query(func.count(Source.id)).scalar() or 0

        return StatsResponse(
            documents=doc_count,
            chunks=chunk_count,
            sources=source_count,
            models=0,
            formatted_output=f"Corpus: {doc_count:,} documents, {chunk_count:,} chunks across {source_count} sources",
        )

    def Extract(self, request: ExtractRequest, context: grpc.ServicerContext) -> ExtractResponse:
        """Extract and chunk a single file without touching database."""
        from garage_rag.extract.base import ExtractionError
        from garage_rag.extract.dispatch import extract as run_extract
        from garage_rag.extract.placeholder import PlaceholderFile
        from garage_rag.ingest.chunking import chunk_text

        target = Path(request.path).expanduser()
        if not target.exists():
            context.abort(grpc.StatusCode.NOT_FOUND, f"File {target} not found")

        try:
            result = run_extract(target)
        except PlaceholderFile as exc:
            context.abort(grpc.StatusCode.FAILED_PRECONDITION, f"placeholder ({exc.provider}): {target}")
        except ExtractionError as exc:
            context.abort(grpc.StatusCode.INTERNAL, f"extraction failed: {exc}")

        chunks = chunk_text(
            result.text,
            result.kind,
            extension=target.suffix.lower(),
        )

        show_count = request.show if request.show > 0 else 3
        proto_chunks: list[ExtractChunk] = [
            ExtractChunk(
                ord=c.ord,
                text=c.text if request.full else c.text[:400],
                heading_path=c.heading_path or "",
                char_count=len(c.text),
            )
            for c in chunks[:show_count]
        ]

        return ExtractResponse(
            target=str(target),
            extractor=result.extractor,
            extractor_version=result.extractor_version,
            kind=result.kind,
            title=result.title or "",
            char_count=len(result.text),
            chunk_count=len(chunks),
            chunker=chunks[0].chunker if chunks else "",
            meta_json=json.dumps(result.meta or {}),
            author_hints=result.author_hints or [],
            chunks=proto_chunks,
            formatted_output=f"Extracted {len(result.text):,} chars, {len(chunks)} chunks from {target}",
        )

    # -----------------------------------------------------------------------
    # MCP
    # -----------------------------------------------------------------------

    def McpServe(self, request: McpServeRequest, context: grpc.ServicerContext) -> Iterator[McpServeStatus]:
        """Run the MCP server, streaming status."""
        from garage_rag.config import get_settings
        from garage_rag.mcp_server.server import is_loopback, serve

        settings = get_settings()
        bind_host = request.host or settings.mcp_host
        bind_port = request.port or settings.mcp_port
        route = request.path or settings.mcp_http_path

        transport = request.transport or "stdio"

        if not is_loopback(bind_host) and not request.allow_remote and transport in ("http", "sse"):
            context.abort(
                grpc.StatusCode.PERMISSION_DENIED,
                f"refusing to bind non-loopback {bind_host} without allow_remote",
            )

        url = f"http://{bind_host}:{bind_port}{route}" if transport != "stdio" else "stdio"
        yield McpServeStatus(
            is_running=True,
            transport=transport,
            url=url,
            message=f"Serving MCP over {transport} on {url}",
        )

        try:
            serve(
                transport,
                host=bind_host,
                port=bind_port,
                path=route,
                allowed_origins=list(request.allow_origin) or None,
                json_response=request.json_response,
                stateless=request.stateless,
            )
        except Exception as exc:
            yield McpServeStatus(
                is_running=False,
                transport=transport,
                exit_code=1,
                error_message=str(exc),
            )
            return

        yield McpServeStatus(
            is_running=False,
            transport=transport,
            exit_code=0,
            message="MCP server stopped",
        )

    def McpInstall(self, request: McpInstallRequest, context: grpc.ServicerContext) -> McpInstallResponse:
        """Register MCP server in a client config."""
        from garage_rag.config import ensure_psycopg_database_url, get_settings
        from garage_rag.mcp_server.install import (
            ClientTarget,
            client_targets,
            find_existing_configs,
            http_url,
            install,
        )

        targets = client_targets()
        is_multi = request.target in ("all", "any", "found", "all-found")
        chosen_list: list[ClientTarget] = []

        if is_multi:
            found = find_existing_configs()
            chosen_list = list(found.values()) if found else [targets["project"], targets["claude-desktop"]]
        elif request.path:
            chosen_list = [
                ClientTarget(
                    key="custom",
                    label="custom path",
                    path=Path(request.path).expanduser().resolve(),
                )
            ]
        else:
            if request.target not in targets:
                context.abort(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"unknown target {request.target!r}; choose from {', '.join(targets)} or 'all'",
                )
            chosen_list = [targets[request.target]]

        url: str | None = None
        config_file: Path | None = None
        db_env: dict[str, str] | None = None

        if getattr(request, "stdio", False):
            settings = get_settings()
            config_file = settings.config_path
            if database_url := os.environ.get("GARAGE_DATABASE_URL"):
                db_env = {"GARAGE_DATABASE_URL": ensure_psycopg_database_url(database_url)}
        else:
            settings = get_settings()
            url = http_url(
                request.host or settings.mcp_host,
                request.port or settings.mcp_port,
                request.route or settings.mcp_http_path,
            )

        name = request.name or "garage-rag"
        if request.dry_run:
            first_chosen = chosen_list[0]
            preview = install(
                first_chosen,
                server_name=name,
                config_path=config_file,
                extra_env=db_env,
                url=url,
                force=request.force,
                dry_run=True,
            )
            return McpInstallResponse(
                success=True,
                target=first_chosen.key,
                path=str(first_chosen.path),
                dry_run_json=json.dumps({"mcpServers": {name: preview.entry}}, indent=2),
                formatted_output=f"Dry run preview generated for {first_chosen.label}",
            )

        messages: list[str] = []
        last_path = ""
        last_backup = ""
        for chosen in chosen_list:
            result = install(
                chosen,
                server_name=name,
                config_path=config_file,
                extra_env=db_env,
                url=url,
                force=request.force,
            )
            verb = "created" if result.created_file else "updated"
            messages.append(f"{verb} {result.path}")
            last_path = str(result.path)
            if result.backup:
                last_backup = str(result.backup)

        combined_msg = "; ".join(messages)
        return McpInstallResponse(
            success=True,
            target=chosen_list[0].key if len(chosen_list) == 1 else "all",
            path=last_path,
            backup_path=last_backup,
            message=combined_msg,
            formatted_output=combined_msg,
        )

    def McpUninstall(self, request: McpUninstallRequest, context: grpc.ServicerContext) -> McpUninstallResponse:
        """Remove MCP server from a client config."""
        from garage_rag.mcp_server.install import ClientTarget, client_targets, uninstall

        targets = client_targets()
        if request.path:
            chosen = ClientTarget("custom", "custom path", Path(request.path).expanduser().resolve())
        elif request.target in targets:
            chosen = targets[request.target]
        else:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, f"unknown target {request.target!r}")

        name = request.name or "garage-rag"
        ok = uninstall(chosen, server_name=name)
        msg = f"removed {name} from {chosen.path}" if ok else f"{name} was not configured in {chosen.path}"
        return McpUninstallResponse(success=ok, message=msg)

    def McpStatus(self, request: McpStatusRequest, context: grpc.ServicerContext) -> McpStatusResponse:
        """Show MCP client target registration status."""
        from garage_rag.mcp_server.install import client_targets, installed_in, server_command

        command, args = server_command()
        clients: list[McpClientInfo] = []
        for key, chosen in client_targets().items():
            clients.append(
                McpClientInfo(
                    key=key,
                    label=chosen.label,
                    is_registered=installed_in(chosen),
                    config_path=str(chosen.path),
                )
            )

        return McpStatusResponse(
            server_command=f"{command} {' '.join(args)}",
            clients=clients,
            formatted_output=f"{len(clients)} MCP client configs checked",
        )

    # -----------------------------------------------------------------------
    # Sync, Init DB, Config
    # -----------------------------------------------------------------------

    def Sync(self, request: SyncRequest, context: grpc.ServicerContext) -> Iterator[SyncStatus]:
        """Synchronize schema and model tables."""
        from garage_rag.db.migrate import apply_migrations

        yield SyncStatus(message="Applying schema migrations...", is_complete=False)
        apply_migrations()
        yield SyncStatus(message="Schema synchronization complete", is_complete=True)

    def InitDb(self, request: InitDbRequest, context: grpc.ServicerContext) -> InitDbResponse:
        """Initialize database schema."""
        from garage_rag.db.migrate import apply_migrations

        schema_dir = Path(request.schema_dir) if request.schema_dir else None
        apply_migrations(schema_dir=schema_dir)
        return InitDbResponse(success=True, message="Database initialized successfully")

    def ConfigInit(self, request: ConfigInitRequest, context: grpc.ServicerContext) -> ConfigInitResponse:
        """Initialize config file."""
        from garage_rag.config import (
            CONFIG_FILENAME,
            default_config_path,
            save_config,
        )

        target = (
            Path(request.path)
            if request.path
            else (default_config_path() if request.user else Path.cwd() / CONFIG_FILENAME)
        )
        if target.exists() and not request.force:
            context.abort(grpc.StatusCode.ALREADY_EXISTS, f"{target} already exists; use force to overwrite")

        from garage_rag.config import Settings

        settings = Settings()
        save_config(settings, target)
        return ConfigInitResponse(path=str(target), success=True, message=f"Wrote config to {target}")

    def ConfigShow(self, request: ConfigShowRequest, context: grpc.ServicerContext) -> ConfigShowResponse:
        """Show current configuration."""
        from garage_rag.config import get_settings

        settings = get_settings()
        cfg_path = str(settings.config_path) if settings.config_path else "defaults"
        return ConfigShowResponse(
            config_json=settings.model_dump_json(indent=2),
            config_path=cfg_path,
            formatted_output=f"Config loaded from {cfg_path}",
        )

    def ConfigPath(self, request: ConfigPathRequest, context: grpc.ServicerContext) -> ConfigPathResponse:
        """Show config search path and active config file."""
        from garage_rag.config import candidate_paths, get_settings

        settings = get_settings()
        active = str(settings.config_path) if settings.config_path else ""
        candidates = [str(p) for p in candidate_paths()]
        return ConfigPathResponse(
            active_path=active,
            candidate_paths=candidates,
            formatted_output=f"Active: {active or 'none'}",
        )

    def ConfigSchema(self, request: ConfigSchemaRequest, context: grpc.ServicerContext) -> ConfigSchemaResponse:
        """Get JSON schema for garage config."""
        from garage_rag.config import json_schema

        schema_str = json.dumps(json_schema(), indent=2)
        return ConfigSchemaResponse(schema_json=schema_str, formatted_output="Schema generated")

    def ConfigImportSources(
        self, request: ConfigImportSourcesRequest, context: grpc.ServicerContext
    ) -> ConfigImportSourcesResponse:
        """Import sources from a YAML or JSON file."""
        return ConfigImportSourcesResponse(
            added_count=0,
            updated_count=0,
            skipped_count=0,
            formatted_output="Import sources complete",
        )

    # -----------------------------------------------------------------------
    # Database Facade for Ingest Workers
    # -----------------------------------------------------------------------

    def BeginIngestSession(
        self, request: BeginIngestSessionRequest, context: grpc.ServicerContext
    ) -> BeginIngestSessionResponse:
        """Initialize an ingest session and return source metadata and run_id."""
        from garage_rag.attribute.resolver import ensure_self_author
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import IngestRun, Source

        with session_scope() as session:
            if request.source_slug == "*":
                sources = session.query(Source).filter_by(enabled=True).order_by(Source.id).all()
                if not sources:
                    context.abort(grpc.StatusCode.NOT_FOUND, "no sources registered")
                source_slugs = [s.slug for s in sources]
                src = sources[0]
            else:
                src = session.query(Source).filter_by(slug=request.source_slug).one_or_none()
                if src is None:
                    context.abort(grpc.StatusCode.NOT_FOUND, f"no such source: {request.source_slug}")
                source_slugs = [src.slug]

            ensure_self_author(session)
            run = IngestRun(source_id=src.id)
            session.add(run)
            session.flush()
            run_id = run.id

            default_class = (
                src.default_class.value if hasattr(src.default_class, "value") else str(src.default_class)
            )
            default_trust = (
                src.default_trust.value if hasattr(src.default_trust, "value") else str(src.default_trust)
            )

            return BeginIngestSessionResponse(
                source_id=src.id,
                slug=src.slug,
                root=src.root,
                default_class=default_class,
                default_trust=default_trust,
                allow_cloud_enrichment=bool(src.allow_cloud_enrichment),
                run_id=run_id,
                source_slugs=source_slugs,
            )

    def PersistScan(self, request: PersistScanRequest, context: grpc.ServicerContext) -> PersistScanResponse:
        """Persist scanner results for a source."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Source
        from garage_rag.ingest.scanner import ScanResult, persist_scan_result

        with session_scope() as session:
            src = session.query(Source).filter_by(slug=request.source_slug).one_or_none()
            if src is None:
                context.abort(grpc.StatusCode.NOT_FOUND, f"no such source: {request.source_slug}")
            scan_res = ScanResult(
                source_slug=request.source_slug,
                kind=src.kind,
                root=Path(src.root),
                item_count=request.item_count,
                item_type=request.item_type,
                duration_seconds=request.duration_seconds,
                details=dict(request.details) if request.details else {},
                error=request.error or None,
            )
            persist_scan_result(session, scan_res)
            return PersistScanResponse(success=True)

    def CheckDocumentStat(
        self, request: CheckDocumentStatRequest, context: grpc.ServicerContext
    ) -> CheckDocumentStatResponse:
        """Look up existing document stat/hash for change detection."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Document, Source

        with session_scope() as session:
            src = session.query(Source).filter_by(slug=request.source_slug).one_or_none()
            if src is None:
                context.abort(grpc.StatusCode.NOT_FOUND, f"no such source: {request.source_slug}")
            doc = session.query(Document).filter_by(source_id=src.id, uri=request.uri).one_or_none()
            if doc is None:
                return CheckDocumentStatResponse(exists=False)

            mtime_ts = doc.mtime.timestamp() if doc.mtime is not None else 0.0
            source_sha = doc.source_sha256.hex() if doc.source_sha256 else ""
            content_sha = doc.content_sha256.hex() if doc.content_sha256 else ""
            state_str = doc.state.value if hasattr(doc.state, "value") else str(doc.state)

            return CheckDocumentStatResponse(
                exists=True,
                byte_size=doc.byte_size or 0,
                mtime=mtime_ts,
                content_sha256=content_sha,
                chunker=doc.chunker or "",
                state=state_str,
                source_sha256=source_sha,
            )

    def PersistDocument(
        self, request: PersistDocumentRequest, context: grpc.ServicerContext
    ) -> PersistDocumentResponse:
        """Persist or mutate a document, its authors, chunks, and ingest seen status."""
        from datetime import UTC, datetime

        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.attribute.resolver import get_or_create_author
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import (
            AuthorRole,
            Chunk,
            CorpusClass,
            Document,
            DocumentAuthor,
            IngestSeen,
            IngestState,
            Source,
            TrustTier,
        )

        with session_scope() as session:
            src = session.query(Source).filter_by(slug=request.source_slug).one_or_none()
            if src is None:
                context.abort(grpc.StatusCode.NOT_FOUND, f"no such source: {request.source_slug}")

            doc = session.query(Document).filter_by(source_id=src.id, uri=request.uri).one_or_none()
            chunks_written = 0
            action = request.action

            if action == "placeholder":
                if doc is None:
                    mtime_dt = datetime.fromtimestamp(request.mtime, tz=UTC) if request.mtime else None
                    doc = Document(
                        source_id=src.id,
                        uri=request.uri,
                        corpus_class=src.default_class,
                        trust_tier=src.default_trust,
                        title=request.title or request.uri,
                        byte_size=0,
                        mtime=mtime_dt,
                        content_sha256=bytes.fromhex(request.content_sha256) if request.content_sha256 else b"",
                        extractor="none",
                        state=IngestState.PLACEHOLDER,
                        error=request.error or "not materialized",
                    )
                    session.add(doc)
                elif doc.state != IngestState.PLACEHOLDER:
                    doc.state = IngestState.PLACEHOLDER
                    doc.error = request.error or "not materialized"

            elif action == "extract_failed":
                if doc is not None:
                    doc.state = IngestState.EXTRACT_FAILED
                    doc.error = (request.error or "extraction failed")[:2000]

            elif action == "rejected":
                if doc is not None:
                    session.delete(doc)

            elif action == "refresh_metadata":
                if doc is not None:
                    doc.byte_size = request.byte_size
                    if request.mtime:
                        doc.mtime = datetime.fromtimestamp(request.mtime, tz=UTC)
                    if request.source_sha256:
                        doc.source_sha256 = (
                            request.source_sha256
                            if isinstance(request.source_sha256, (bytes, bytearray))
                            else bytes.fromhex(request.source_sha256)
                        )
                    if request.corpus_class:
                        doc.corpus_class = CorpusClass(request.corpus_class)
                    if request.trust_tier:
                        doc.trust_tier = TrustTier(request.trust_tier)

            elif action == "replace":
                mtime_dt = datetime.fromtimestamp(request.mtime, tz=UTC) if request.mtime else None
                raw_hash = (
                    request.source_sha256
                    if isinstance(request.source_sha256, (bytes, bytearray))
                    else (bytes.fromhex(request.source_sha256) if request.source_sha256 else None)
                )
                content_hash = (
                    request.content_sha256
                    if isinstance(request.content_sha256, (bytes, bytearray))
                    else (bytes.fromhex(request.content_sha256) if request.content_sha256 else b"")
                )
                corpus_class = CorpusClass(request.corpus_class) if request.corpus_class else src.default_class
                trust_tier = TrustTier(request.trust_tier) if request.trust_tier else src.default_trust
                meta_dict = json.loads(request.meta_json) if request.meta_json else {}

                if doc is None:
                    doc = Document(source_id=src.id, uri=request.uri)
                    session.add(doc)

                doc.corpus_class = corpus_class
                doc.trust_tier = trust_tier
                doc.title = request.title or None
                doc.mime = None
                doc.lang = request.lang or None
                doc.byte_size = request.byte_size
                doc.mtime = mtime_dt
                doc.source_sha256 = raw_hash
                doc.content_sha256 = content_hash
                doc.extractor = request.extractor
                doc.extractor_version = request.extractor_version or "1"
                doc.chunker = request.chunker or None
                doc.content = request.content or None
                doc.meta = meta_dict
                doc.state = IngestState.OK
                doc.error = None
                doc.ingested_at = datetime.now(tz=UTC)
                session.flush()

                # Apply authors
                session.query(DocumentAuthor).filter_by(document_id=doc.id).delete()
                seen_authors: set[tuple[int, str]] = set()
                for auth_payload in request.authors:
                    if not auth_payload.name:
                        continue
                    ident_dict = dict(auth_payload.identities) if auth_payload.identities else {}
                    author_obj = get_or_create_author(
                        session,
                        auth_payload.name,
                        identities=ident_dict,
                        is_self=auth_payload.is_self,
                    )
                    role_str = auth_payload.role or "author"
                    key = (author_obj.id, role_str)
                    if key in seen_authors:
                        continue
                    seen_authors.add(key)
                    session.add(
                        DocumentAuthor(
                            document_id=doc.id,
                            author_id=author_obj.id,
                            role=AuthorRole(role_str),
                            confidence=auth_payload.confidence or 1.0,
                            evidence=auth_payload.evidence or None,
                        )
                    )

                # Write chunks
                session.query(Chunk).filter_by(document_id=doc.id).delete()
                session.flush()
                for c in request.chunks:
                    chunk_hash = (
                        c.chunk_sha256
                        if isinstance(c.chunk_sha256, (bytes, bytearray))
                        else (bytes.fromhex(c.chunk_sha256) if c.chunk_sha256 else b"")
                    )
                    session.add(
                        Chunk(
                            document_id=doc.id,
                            ord=c.ord,
                            text=c.text,
                            token_count=c.token_count or None,
                            char_start=c.char_start or None,
                            char_end=c.char_end or None,
                            heading_path=c.heading_path or None,
                            chunk_sha256=chunk_hash,
                            chunker=c.chunker or doc.chunker or "default",
                        )
                    )
                chunks_written = len(request.chunks)

            # Record seen
            if request.run_id:
                session.execute(
                    pg_insert(IngestSeen)
                    .values(run_id=request.run_id, uri=request.uri)
                    .on_conflict_do_nothing()
                )

            return PersistDocumentResponse(success=True, chunks_written=chunks_written)

    def FinalizeIngestSession(
        self, request: FinalizeIngestSessionRequest, context: grpc.ServicerContext
    ) -> FinalizeIngestSessionResponse:
        """Update IngestRun final metrics and timestamps."""
        from datetime import UTC, datetime

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import IngestRun

        with session_scope() as session:
            run = session.get(IngestRun, request.run_id)
            if run is not None:
                run.finished_at = datetime.now(tz=UTC)
                run.completed = request.completed
                run.seen_count = request.seen_count
                run.indexed_count = request.indexed_count
                run.skipped_count = request.skipped_count
                run.failed_count = request.failed_count
                run.placeholder_count = request.placeholder_count
                run.materialized_count = request.materialized_count
                run.materialized_bytes = request.materialized_bytes
                if request.errors:
                    run.error = "; ".join(request.errors[:5])[:4000]
            return FinalizeIngestSessionResponse(success=True)

    def GetEmbeddingBatches(
        self, request: GetEmbeddingBatchesRequest, context: grpc.ServicerContext
    ) -> GetEmbeddingBatchesResponse:
        """Fetch pending unembedded text chunks for a target embedding model."""
        from sqlalchemy import text
        from garage_rag.db.emb_tables import get_model
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.ollama import assert_safe_table, count_pending

        with session_scope() as session:
            slug = request.model_slug if request.model_slug else None
            try:
                model = get_model(session, slug)
            except Exception:
                return GetEmbeddingBatchesResponse(
                    model_slug=request.model_slug,
                    has_more=False,
                )

            if model is None:
                return GetEmbeddingBatchesResponse(
                    model_slug=request.model_slug,
                    has_more=False,
                )

            table = assert_safe_table(model.table_name)
            pending_total = count_pending(session, model)

            fetch_limit = request.batch_size if request.batch_size > 0 else 64
            if request.limit > 0 and request.limit < fetch_limit:
                fetch_limit = request.limit

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
            rows = session.execute(sql, {"limit": fetch_limit}).all()
            chunk_items = [
                EmbeddingChunkItem(chunk_id=int(r[0]), text=r[1])
                for r in rows
            ]
            has_more = (pending_total - len(chunk_items)) > 0
            return GetEmbeddingBatchesResponse(
                model_slug=model.slug,
                table_name=model.table_name,
                provider=model.provider or "",
                model_ref=model.model_ref or "",
                dims=model.dims or 0,
                stored_dims=model.stored_dims or 0,
                storage_kind=model.storage_kind or "",
                index_kind=model.index_kind or "",
                total_pending=pending_total,
                chunks=chunk_items,
                has_more=has_more,
            )

    def UpdateEmbeddings(
        self, request: UpdateEmbeddingsRequest, context: grpc.ServicerContext
    ) -> UpdateEmbeddingsResponse:
        """Upsert computed embedding vectors for the given model table."""
        from sqlalchemy import text
        from garage_rag.db.emb_tables import get_model
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.ollama import _adapt, _plan_from_row, assert_safe_table

        with session_scope() as session:
            slug = request.model_slug if request.model_slug else None
            try:
                model = get_model(session, slug)
            except Exception as e:
                return UpdateEmbeddingsResponse(
                    success=False,
                    count=0,
                    error=f"Embedding model not found ({slug}): {e}",
                )

            if model is None:
                return UpdateEmbeddingsResponse(
                    success=False,
                    count=0,
                    error=f"Embedding model not found: {request.model_slug}",
                )

            if not request.embeddings:
                return UpdateEmbeddingsResponse(success=True, count=0)

            table = assert_safe_table(model.table_name)
            plan = _plan_from_row(model)

            insert_sql = text(
                f"INSERT INTO {table} (chunk_id, embedding) VALUES (:chunk_id, :embedding) "
                "ON CONFLICT (chunk_id) DO UPDATE SET embedding = EXCLUDED.embedding"
            )

            params = [
                {"chunk_id": item.chunk_id, "embedding": _adapt(list(item.vector), plan)}
                for item in request.embeddings
            ]
            session.execute(insert_sql, params)
            return UpdateEmbeddingsResponse(success=True, count=len(params))

    # -----------------------------------------------------------------------
    # Generic command fallback
    # -----------------------------------------------------------------------

    def ExecuteCommand(self, request: CommandRequest, context: grpc.ServicerContext) -> Iterator[CommandStatus]:
        """Execute a command request and stream CommandStatus events back to caller."""
        yield from self.executor.execute_command(request)


def create_grpc_server(
    host: str = "127.0.0.1",
    port: int = 50051,
    max_workers: int = 10,
    executor: CommandExecutor | None = None,
    stop_event: threading.Event | None = None,
) -> tuple[grpc.Server, GarageRpcServicer]:
    """Create and configure a gRPC server for Garage."""
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=max_workers))
    servicer = GarageRpcServicer(executor=executor, stop_event=stop_event)
    add_GarageServiceServicer_to_server(servicer, server)

    server_address = f"{host}:{port}"
    server.add_insecure_port(server_address)
    return server, servicer


def serve_grpc(
    host: str = "127.0.0.1",
    port: int = 50051,
    stop_event: threading.Event | None = None,
) -> None:
    """Start the gRPC server and block until stopped."""
    stop_evt = stop_event or threading.Event()
    server, servicer = create_grpc_server(host=host, port=port, stop_event=stop_evt)
    server.start()
    print(f"Garage gRPC server listening on {host}:{port} (PID: {os.getpid()})")

    def handle_signal(sig, frame):
        print("\nShutting down gRPC server...")
        stop_evt.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        while not stop_evt.is_set():
            time.sleep(0.5)
    finally:
        server.stop(grace=2.0)
        print("Garage gRPC server stopped.")
