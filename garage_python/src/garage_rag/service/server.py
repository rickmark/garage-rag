"""gRPC server for ``GarageService``: the bridge between the macOS app and the Python pipeline.

The app's Search and Documents views read the corpus through it, and the ingest and
embed XPC workers persist through its database facade. Everything that mutates
configuration or runs a pipeline stage is a ``garage`` CLI command the app invokes
directly, so the servicer carries no copies of CLI command bodies: each handler
translates protobuf messages to and from the plain functions the CLI also calls.
"""

from __future__ import annotations

import functools
import json
import logging
import os
import signal
import threading
import time
from collections.abc import Callable
from concurrent import futures
from pathlib import Path
from typing import Any, cast

import grpc

from garage_rag.proto.garage_pb2 import (
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    DocumentAuthorInfo,
    DocumentChunkInfo,
    DocumentDetail,
    DocumentFactInfo,
    DocumentSummary,
    EmbeddingChunkItem,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    GetDocumentRequest,
    GetDocumentResponse,
    GetEmbeddingBatchesRequest,
    GetEmbeddingBatchesResponse,
    ListDocumentsRequest,
    ListDocumentsResponse,
    ListModelsRequest,
    ListModelsResponse,
    ListSourcesRequest,
    ListSourcesResponse,
    ModelInfo,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    PersistScanResponse,
    PingRequest,
    PingResponse,
    SearchHit,
    SearchRequest,
    SearchResponse,
    SourceInfo,
    StatsRequest,
    StatsResponse,
    StatusRequest,
    StatusResponse,
    UpdateEmbeddingsRequest,
    UpdateEmbeddingsResponse,
    VersionRequest,
    VersionResponse,
)
from garage_rag.proto.garage_pb2_grpc import (
    GarageServiceServicer,
    add_GarageServiceServicer_to_server,
)

logger = logging.getLogger(__name__)


def _version() -> str:
    """Package version as reported by the CLI (``garage version``)."""
    # Imported here, not at module scope: garage_rag/__init__ pulls in the
    # submodules that import this one, so a top-level import would be a cycle.
    # gazelle:ignore garage_rag
    import garage_rag

    # ty only sees this target's sources, and garage_rag/__init__.py is not one
    # of them (that dependency is the cycle the local import breaks), so the
    # package resolves here without its attributes.
    return garage_rag.__version__  # ty: ignore[unresolved-attribute]


# Exceptions the plain functions raise, in the gRPC status they mean. Order matters:
# FileExistsError and PermissionError are OSErrors and must not fall through to a
# broader match, and only these four are translated; anything else is a server
# fault and stays UNKNOWN so it is never mistaken for a client error.
_STATUS_FOR_EXCEPTION: tuple[tuple[type[Exception], grpc.StatusCode], ...] = (
    (FileExistsError, grpc.StatusCode.ALREADY_EXISTS),
    (PermissionError, grpc.StatusCode.PERMISSION_DENIED),
    (LookupError, grpc.StatusCode.NOT_FOUND),
    (ValueError, grpc.StatusCode.INVALID_ARGUMENT),
)


def _grpc_errors[**P, R](handler: Callable[P, R]) -> Callable[P, R]:
    """Abort the RPC with the status code an exception from the handler implies."""

    @functools.wraps(handler)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        context = cast(grpc.ServicerContext, args[2] if len(args) > 2 else kwargs["context"])
        try:
            return handler(*args, **kwargs)
        except Exception as exc:
            for exc_type, code in _STATUS_FOR_EXCEPTION:
                if isinstance(exc, exc_type):
                    context.abort(code, str(exc))
            raise

    return wrapper


def _enum_value(value: Any) -> str:
    return value.value if hasattr(value, "value") else str(value)


class GarageRpcServicer(GarageServiceServicer):
    """gRPC servicer implementing ``GarageService``."""

    def __init__(self, stop_event: threading.Event | None = None) -> None:
        self.stop_event = stop_event or threading.Event()

    # -----------------------------------------------------------------------
    # System / Lifecycle
    # -----------------------------------------------------------------------

    @_grpc_errors
    def Ping(self, request: PingRequest, context: grpc.ServicerContext) -> PingResponse:
        """Ping / Healthcheck."""
        return PingResponse(
            message=request.message or "pong",
            timestamp=int(time.time()),
        )

    @_grpc_errors
    def GetStatus(self, request: StatusRequest, context: grpc.ServicerContext) -> StatusResponse:
        """Retrieve server and database status."""
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
            version=_version(),
            is_ready=is_ready,
            pid=os.getpid(),
            db_status=db_status,
            server_type="grpc",
        )

    @_grpc_errors
    def GetVersion(self, request: VersionRequest, context: grpc.ServicerContext) -> VersionResponse:
        """Get the garage version."""
        return VersionResponse(version=_version())

    # -----------------------------------------------------------------------
    # Search
    # -----------------------------------------------------------------------

    @_grpc_errors
    def Search(self, request: SearchRequest, context: grpc.ServicerContext) -> SearchResponse:
        """Search the corpus with hybrid vector + keyword retrieval."""
        from garage_rag.db.engine import session_scope
        from garage_rag.search.hybrid import SearchMode, snippet
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
                    snippet=hit.text if request.full else snippet(hit.text),
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

    @_grpc_errors
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
                query.order_by(Document.ingested_at.desc(), Document.id.desc()).offset(offset).limit(limit).all()
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

    @_grpc_errors
    def GetDocument(self, request: GetDocumentRequest, context: grpc.ServicerContext) -> GetDocumentResponse:
        """Fetch a single document's metadata and its chunks."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Fact, Source

        with session_scope() as session:
            document = session.get(Document, request.document_id)
            if document is None:
                context.abort(grpc.StatusCode.NOT_FOUND, f"document {request.document_id} not found")

            source = session.get(Source, document.source_id)

            chunks = session.query(Chunk).filter(Chunk.document_id == document.id).order_by(Chunk.ord.asc()).all()

            facts = session.query(Fact).filter(Fact.document_id == document.id).order_by(Fact.ord.asc()).all()

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

    @_grpc_errors
    def ListSources(self, request: ListSourcesRequest, context: grpc.ServicerContext) -> ListSourcesResponse:
        """List registered sources."""
        from sqlalchemy import func

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Document, Source

        with session_scope() as session:
            sources = session.query(Source).order_by(Source.id).all()
            doc_counts = dict(
                session.query(Document.source_id, func.count(Document.id)).group_by(Document.source_id).all()
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

    # -----------------------------------------------------------------------
    # Embedding models & stats
    # -----------------------------------------------------------------------

    @_grpc_errors
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

    @_grpc_errors
    def GetStats(self, request: StatsRequest, context: grpc.ServicerContext) -> StatsResponse:
        """Row counts across the corpus, per source and per embedding model."""
        from sqlalchemy import func

        from garage_rag.db.emb_tables import count_vectors, list_models
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Source

        with session_scope() as session:
            doc_count = session.query(func.count(Document.id)).scalar() or 0
            chunk_count = session.query(func.count(Chunk.id)).scalar() or 0
            source_count = session.query(func.count(Source.id)).scalar() or 0
            documents_by_source = {
                slug: int(count)
                for slug, count in session.query(Source.slug, func.count(Document.id))
                .outerjoin(Document, Document.source_id == Source.id)
                .group_by(Source.slug)
                .all()
            }
            models = list_models(session)
            chunks_by_model = {m.slug: count_vectors(session, m) for m in models}

        return StatsResponse(
            documents=doc_count,
            chunks=chunk_count,
            sources=source_count,
            models=len(models),
            chunks_by_model=chunks_by_model,
            documents_by_source=documents_by_source,
            formatted_output=(
                f"Corpus: {doc_count:,} documents, {chunk_count:,} chunks across "
                f"{source_count} sources, {len(models)} embedding models"
            ),
        )

    # -----------------------------------------------------------------------
    # Database facade for the ingest worker
    #
    # ``GrpcIngestStorageGateway`` (ingest/gateway.py) is the client side of these
    # RPCs; the server side is the SQLAlchemy gateway the in-process pipeline uses,
    # so both paths persist through one implementation.
    # -----------------------------------------------------------------------

    @staticmethod
    def _ingest_gateway():
        from garage_rag.db.engine import session_scope
        from garage_rag.ingest.gateway import SqlAlchemyIngestStorageGateway

        return SqlAlchemyIngestStorageGateway(session_scope)

    @_grpc_errors
    def BeginIngestSession(
        self, request: BeginIngestSessionRequest, context: grpc.ServicerContext
    ) -> BeginIngestSessionResponse:
        """Open an ingest run for a source (or ``*`` for every enabled one)."""
        ctx = self._ingest_gateway().begin_session(request.source_slug, include_code=request.include_code)
        return BeginIngestSessionResponse(
            source_id=ctx.source_id,
            slug=ctx.slug,
            root=str(ctx.root),
            default_class=_enum_value(ctx.default_class),
            default_trust=_enum_value(ctx.default_trust),
            allow_cloud_enrichment=ctx.allow_cloud_enrichment,
            run_id=ctx.run_id,
            source_slugs=ctx.source_slugs,
        )

    @_grpc_errors
    def PersistScan(self, request: PersistScanRequest, context: grpc.ServicerContext) -> PersistScanResponse:
        """Record a source scan's expected element count."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Source
        from garage_rag.ingest.scanner import ScanResult

        with session_scope() as session:
            src = session.query(Source).filter_by(slug=request.source_slug).one_or_none()
            if src is None:
                raise LookupError(f"No such source: {request.source_slug}")
            kind, root = src.kind, Path(src.root)
        self._ingest_gateway().persist_scan(
            request.source_slug,
            ScanResult(
                source_slug=request.source_slug,
                kind=kind,
                root=root,
                item_count=request.item_count,
                item_type=request.item_type,
                duration_seconds=request.duration_seconds,
                details=dict(request.details) if request.details else {},
                error=request.error or None,
            ),
        )
        return PersistScanResponse(success=True)

    @_grpc_errors
    def CheckDocumentStat(
        self, request: CheckDocumentStatRequest, context: grpc.ServicerContext
    ) -> CheckDocumentStatResponse:
        """Existing stat and hashes of a document, for change detection."""
        stat = self._ingest_gateway().check_stat(request.source_slug, request.uri)
        return CheckDocumentStatResponse(
            exists=stat.exists,
            byte_size=stat.byte_size,
            mtime=stat.mtime,
            content_sha256=stat.content_sha256,
            chunker=stat.chunker,
            state=stat.state,
            source_sha256=stat.source_sha256,
        )

    @_grpc_errors
    def PersistDocument(
        self, request: PersistDocumentRequest, context: grpc.ServicerContext
    ) -> PersistDocumentResponse:
        """Apply one ingest outcome to a document; ``action`` picks the gateway method."""
        from garage_rag.ingest.gateway import AuthorPayload, ChunkPayload

        gw = self._ingest_gateway()
        run_id, slug, uri = request.run_id, request.source_slug, request.uri
        chunks_written = 0
        match request.action:
            case "placeholder":
                gw.record_placeholder(run_id, slug, uri, request.mtime, request.title, request.error)
            case "extract_failed":
                gw.record_extract_failed(run_id, slug, uri, request.error or "extraction failed")
            case "rejected":
                gw.record_rejected(run_id, slug, uri)
            case "seen":
                gw.record_seen(run_id, slug, uri)
            case "refresh_metadata":
                gw.refresh_metadata(
                    run_id,
                    slug,
                    uri,
                    byte_size=request.byte_size,
                    mtime=request.mtime,
                    source_sha256=request.source_sha256,
                    corpus_class=request.corpus_class,
                    trust_tier=request.trust_tier,
                )
            case "replace":
                chunks_written = gw.replace_document(
                    run_id,
                    slug,
                    uri,
                    title=request.title or None,
                    lang=request.lang or None,
                    byte_size=request.byte_size,
                    mtime=request.mtime,
                    source_sha256=request.source_sha256 or None,
                    content_sha256=request.content_sha256,
                    extractor=request.extractor,
                    extractor_version=request.extractor_version or "1",
                    chunker=request.chunker or None,
                    content=request.content or None,
                    meta=json.loads(request.meta_json) if request.meta_json else {},
                    corpus_class=request.corpus_class,
                    trust_tier=request.trust_tier,
                    authors=[
                        AuthorPayload(
                            name=a.name,
                            role=a.role or "author",
                            confidence=a.confidence or 1.0,
                            evidence=a.evidence or None,
                            identities=dict(a.identities),
                            is_self=a.is_self,
                        )
                        for a in request.authors
                    ],
                    chunks=[
                        ChunkPayload(
                            ord=c.ord,
                            text=c.text,
                            token_count=c.token_count or None,
                            char_start=c.char_start or None,
                            char_end=c.char_end or None,
                            heading_path=c.heading_path or None,
                            chunk_sha256=c.chunk_sha256,
                            chunker=c.chunker or None,
                        )
                        for c in request.chunks
                    ],
                )
            case other:
                raise ValueError(f"unknown PersistDocument action {other!r}")
        return PersistDocumentResponse(success=True, chunks_written=chunks_written)

    @_grpc_errors
    def FinalizeIngestSession(
        self, request: FinalizeIngestSessionRequest, context: grpc.ServicerContext
    ) -> FinalizeIngestSessionResponse:
        """Close the ingest run with its final counts."""
        self._ingest_gateway().finalize_session(
            request.run_id,
            completed=request.completed,
            seen=request.seen_count,
            indexed=request.indexed_count,
            skipped=request.skipped_count,
            failed=request.failed_count,
            placeholders=request.placeholder_count,
            materialized=request.materialized_count,
            materialized_bytes=request.materialized_bytes,
            errors=list(request.errors),
        )
        return FinalizeIngestSessionResponse(success=True)

    # -----------------------------------------------------------------------
    # Database facade for the embed worker
    # -----------------------------------------------------------------------

    @_grpc_errors
    def GetEmbeddingBatches(
        self, request: GetEmbeddingBatchesRequest, context: grpc.ServicerContext
    ) -> GetEmbeddingBatchesResponse:
        """Fetch pending unembedded text chunks for a target embedding model."""
        from sqlalchemy import text

        from garage_rag.db.emb_tables import get_model
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.ollama import assert_safe_table, count_pending

        with session_scope() as session:
            # get_model raises LookupError (NOT_FOUND) for an unknown slug only; a DB
            # outage propagates as an error rather than an empty "nothing to embed".
            model = get_model(session, request.model_slug or None)
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
            chunk_items = [EmbeddingChunkItem(chunk_id=int(r[0]), text=r[1]) for r in rows]
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

    @_grpc_errors
    def UpdateEmbeddings(
        self, request: UpdateEmbeddingsRequest, context: grpc.ServicerContext
    ) -> UpdateEmbeddingsResponse:
        """Upsert computed embedding vectors for the given model table."""
        from sqlalchemy import text

        from garage_rag.db.emb_tables import get_model
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.ollama import _adapt, _plan_from_row, assert_safe_table

        with session_scope() as session:
            model = get_model(session, request.model_slug or None)
            if not request.embeddings:
                return UpdateEmbeddingsResponse(success=True, count=0)

            table = assert_safe_table(model.table_name)
            plan = _plan_from_row(model)

            insert_sql = text(
                f"INSERT INTO {table} (chunk_id, embedding) VALUES (:chunk_id, :embedding) "
                "ON CONFLICT (chunk_id) DO UPDATE SET embedding = EXCLUDED.embedding"
            )

            params = [
                {"chunk_id": item.chunk_id, "embedding": _adapt(list(item.vector), plan)} for item in request.embeddings
            ]
            session.execute(insert_sql, params)
            return UpdateEmbeddingsResponse(success=True, count=len(params))


def create_grpc_server(
    host: str = "127.0.0.1",
    port: int = 50051,
    max_workers: int = 10,
    stop_event: threading.Event | None = None,
    stop_grace: float = 2.0,
) -> tuple[grpc.Server, GarageRpcServicer]:
    """Create and configure a gRPC server for Garage.

    When ``stop_event`` is given, setting it stops the server with ``stop_grace``
    seconds of grace; ``serve_grpc`` sets it from SIGINT/SIGTERM.
    """
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=max_workers))
    servicer = GarageRpcServicer(stop_event=stop_event)
    add_GarageServiceServicer_to_server(servicer, server)

    server_address = f"{host}:{port}"
    server.add_insecure_port(server_address)

    if stop_event is not None:
        # The CLI loop polls the event, the Swift host calls server.stop() itself;
        # watching the event here makes it effective for both.
        def _stop_on_event() -> None:
            stop_event.wait()
            server.stop(grace=stop_grace)

        threading.Thread(target=_stop_on_event, name="garage-grpc-stop-watcher", daemon=True).start()
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
