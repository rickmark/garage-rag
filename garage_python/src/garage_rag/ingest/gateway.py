"""Storage Gateway abstraction for ingestion persistence.

Supports direct SQLAlchemy database sessions as well as gRPC proxying (facade)
for sandboxed XPC workers.
"""

from __future__ import annotations

import json
import logging
import os
from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.ingest.scanner import ScanResult

logger = logging.getLogger(__name__)


@dataclass
class SourceContext:
    source_id: int
    slug: str
    root: Path
    default_class: CorpusClass
    default_trust: TrustTier
    allow_cloud_enrichment: bool
    run_id: int
    kind: str = "filesystem"
    source_slugs: list[str] = field(default_factory=list)


@dataclass
class ExistingDocStat:
    exists: bool
    byte_size: int = 0
    mtime: float = 0.0
    content_sha256: str = ""
    chunker: str = ""
    state: str = ""
    source_sha256: str = ""


@dataclass
class AuthorPayload:
    name: str
    role: str = "author"
    confidence: float = 1.0
    evidence: str | None = None
    identities: dict[str, str] = field(default_factory=dict)
    is_self: bool = False


@dataclass
class ChunkPayload:
    ord: int
    text: str
    token_count: int | None = None
    char_start: int | None = None
    char_end: int | None = None
    heading_path: str | None = None
    chunk_sha256: str = ""
    chunker: str | None = None


class IngestStorageGateway(ABC):
    """Abstract interface for ingestion persistence operations."""

    @abstractmethod
    def list_enabled_sources(self) -> list[str]:
        """Slugs of every enabled source, in registration order. Opens no ingest run."""

    @abstractmethod
    def begin_session(self, source_slug: str, include_code: bool = False) -> SourceContext:
        """Initialize ingest run session for a source."""

    @abstractmethod
    def persist_scan(self, source_slug: str, scan_result: ScanResult) -> None:
        """Persist scanner stats."""

    @abstractmethod
    def check_stat(self, source_slug: str, uri: str) -> ExistingDocStat:
        """Check existing document metadata and checksums."""

    @abstractmethod
    def record_placeholder(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        mtime: float,
        title: str,
        error: str = "",
    ) -> None:
        """Record placeholder document for unmaterialized files."""

    @abstractmethod
    def record_extract_failed(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        error: str,
    ) -> None:
        """Record extraction failure."""

    @abstractmethod
    def record_rejected(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
    ) -> None:
        """Record document rejection (deleting existing)."""

    @abstractmethod
    def record_seen(self, run_id: int, source_slug: str, uri: str) -> None:
        """Record that ``uri`` was observed by this run without touching its document row.

        Used for files the pipeline never opened (stat-skipped) or could not turn into
        chunks; reconciliation would otherwise treat them as deleted.
        """

    @abstractmethod
    def refresh_metadata(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        byte_size: int,
        mtime: float,
        source_sha256: str,
        corpus_class: str,
        trust_tier: str,
    ) -> None:
        """Refresh metadata for unchanged document."""

    @abstractmethod
    def replace_document(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        title: str | None,
        lang: str | None,
        byte_size: int,
        mtime: float,
        source_sha256: str | None,
        content_sha256: str,
        extractor: str,
        extractor_version: str,
        chunker: str | None,
        content: str | None,
        meta: dict[str, Any],
        corpus_class: str,
        trust_tier: str,
        authors: list[AuthorPayload],
        chunks: list[ChunkPayload],
    ) -> int:
        """Replace document, authors, and chunks, returning number of chunks written."""

    @abstractmethod
    def finalize_session(
        self,
        run_id: int,
        completed: bool,
        seen: int,
        indexed: int,
        skipped: int,
        failed: int,
        placeholders: int,
        materialized: int,
        materialized_bytes: int,
        errors: list[str],
    ) -> None:
        """Update final run statistics."""


class SqlAlchemyIngestStorageGateway(IngestStorageGateway):
    """Direct database gateway using SQLAlchemy session factory."""

    def __init__(self, session_factory: Callable[[], Any]) -> None:
        self.factory = session_factory

    def list_enabled_sources(self) -> list[str]:
        from garage_rag.db.models import Source

        with self.factory() as session:
            return [s.slug for s in session.query(Source).filter_by(enabled=True).order_by(Source.id).all()]

    def begin_session(self, source_slug: str, include_code: bool = False) -> SourceContext:
        from garage_rag.attribute.resolver import ensure_self_author
        from garage_rag.db.models import IngestRun, Source

        with self.factory() as session:
            if source_slug == "*":
                sources = session.query(Source).filter_by(enabled=True).order_by(Source.id).all()
                if not sources:
                    raise RuntimeError("No sources registered")
                source_slugs = [s.slug for s in sources]
                src = sources[0]
            else:
                src = session.query(Source).filter_by(slug=source_slug).one_or_none()
                if src is None:
                    raise RuntimeError(f"No such source: {source_slug}")
                source_slugs = [src.slug]

            ensure_self_author(session)
            run = IngestRun(source_id=src.id)
            session.add(run)
            session.commit()

            return SourceContext(
                source_id=src.id,
                slug=src.slug,
                root=Path(src.root),
                default_class=src.default_class,
                default_trust=src.default_trust,
                allow_cloud_enrichment=bool(src.allow_cloud_enrichment),
                run_id=run.id,
                kind=src.kind,
                source_slugs=source_slugs,
            )

    def persist_scan(self, source_slug: str, scan_result: ScanResult) -> None:
        from garage_rag.ingest.scanner import persist_scan_result

        with self.factory() as session:
            persist_scan_result(session, scan_result)
            session.commit()

    def check_stat(self, source_slug: str, uri: str) -> ExistingDocStat:
        from garage_rag.db.models import Document, Source

        with self.factory() as session:
            src = session.query(Source).filter_by(slug=source_slug).one_or_none()
            if src is None:
                raise RuntimeError(f"No such source: {source_slug}")
            doc = session.query(Document).filter_by(source_id=src.id, uri=uri).one_or_none()
            if doc is None:
                return ExistingDocStat(exists=False)

            mtime_ts = doc.mtime.timestamp() if doc.mtime is not None else 0.0
            source_sha = doc.source_sha256.hex() if doc.source_sha256 else ""
            content_sha = doc.content_sha256.hex() if doc.content_sha256 else ""
            state_str = doc.state.value if hasattr(doc.state, "value") else str(doc.state)

            return ExistingDocStat(
                exists=True,
                byte_size=doc.byte_size or 0,
                mtime=mtime_ts,
                content_sha256=content_sha,
                chunker=doc.chunker or "",
                state=state_str,
                source_sha256=source_sha,
            )

    def record_placeholder(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        mtime: float,
        title: str,
        error: str = "",
    ) -> None:
        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.db.models import Document, IngestSeen, IngestState, Source

        with self.factory() as session:
            src = session.query(Source).filter_by(slug=source_slug).one_or_none()
            if src is None:
                raise RuntimeError(f"No such source: {source_slug}")
            doc = session.query(Document).filter_by(source_id=src.id, uri=uri).one_or_none()
            if doc is None:
                mtime_dt = datetime.fromtimestamp(mtime, tz=UTC) if mtime else None
                doc = Document(
                    source_id=src.id,
                    uri=uri,
                    corpus_class=src.default_class,
                    trust_tier=src.default_trust,
                    title=title or uri,
                    byte_size=0,
                    mtime=mtime_dt,
                    content_sha256=b"",
                    extractor="none",
                    state=IngestState.PLACEHOLDER,
                    error=error or "not materialized",
                )
                session.add(doc)
            elif doc.state != IngestState.PLACEHOLDER:
                doc.state = IngestState.PLACEHOLDER
                doc.error = error or "not materialized"

            if run_id:
                session.execute(pg_insert(IngestSeen).values(run_id=run_id, uri=uri).on_conflict_do_nothing())
            session.commit()

    def record_extract_failed(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        error: str,
    ) -> None:
        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.db.models import Document, IngestSeen, IngestState, Source

        with self.factory() as session:
            src = session.query(Source).filter_by(slug=source_slug).one_or_none()
            if src is None:
                raise RuntimeError(f"No such source: {source_slug}")
            doc = session.query(Document).filter_by(source_id=src.id, uri=uri).one_or_none()
            if doc is not None:
                doc.state = IngestState.EXTRACT_FAILED
                doc.error = error[:2000]

            if run_id:
                session.execute(pg_insert(IngestSeen).values(run_id=run_id, uri=uri).on_conflict_do_nothing())
            session.commit()

    def record_rejected(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
    ) -> None:
        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.db.models import Document, IngestSeen, Source

        with self.factory() as session:
            src = session.query(Source).filter_by(slug=source_slug).one_or_none()
            if src is None:
                raise RuntimeError(f"No such source: {source_slug}")
            doc = session.query(Document).filter_by(source_id=src.id, uri=uri).one_or_none()
            if doc is not None:
                session.delete(doc)

            if run_id:
                session.execute(pg_insert(IngestSeen).values(run_id=run_id, uri=uri).on_conflict_do_nothing())
            session.commit()

    def record_seen(self, run_id: int, source_slug: str, uri: str) -> None:
        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.db.models import IngestSeen

        if not run_id:
            return
        with self.factory() as session:
            session.execute(pg_insert(IngestSeen).values(run_id=run_id, uri=uri).on_conflict_do_nothing())
            session.commit()

    def refresh_metadata(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        byte_size: int,
        mtime: float,
        source_sha256: str,
        corpus_class: str,
        trust_tier: str,
    ) -> None:
        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.db.models import CorpusClass, Document, IngestSeen, Source, TrustTier

        with self.factory() as session:
            src = session.query(Source).filter_by(slug=source_slug).one_or_none()
            if src is None:
                raise RuntimeError(f"No such source: {source_slug}")
            doc = session.query(Document).filter_by(source_id=src.id, uri=uri).one_or_none()
            if doc is not None:
                doc.byte_size = byte_size
                if mtime:
                    doc.mtime = datetime.fromtimestamp(mtime, tz=UTC)
                if source_sha256:
                    doc.source_sha256 = (
                        source_sha256 if isinstance(source_sha256, (bytes, bytearray)) else bytes.fromhex(source_sha256)
                    )
                if corpus_class:
                    doc.corpus_class = CorpusClass(corpus_class)
                if trust_tier:
                    doc.trust_tier = TrustTier(trust_tier)

            if run_id:
                session.execute(pg_insert(IngestSeen).values(run_id=run_id, uri=uri).on_conflict_do_nothing())
            session.commit()

    def replace_document(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        title: str | None,
        lang: str | None,
        byte_size: int,
        mtime: float,
        source_sha256: str | None,
        content_sha256: str,
        extractor: str,
        extractor_version: str,
        chunker: str | None,
        content: str | None,
        meta: dict[str, Any],
        corpus_class: str,
        trust_tier: str,
        authors: list[AuthorPayload],
        chunks: list[ChunkPayload],
    ) -> int:
        from sqlalchemy.dialects.postgresql import insert as pg_insert

        from garage_rag.attribute.resolver import get_or_create_author
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

        with self.factory() as session:
            src = session.query(Source).filter_by(slug=source_slug).one_or_none()
            if src is None:
                raise RuntimeError(f"No such source: {source_slug}")

            doc = session.query(Document).filter_by(source_id=src.id, uri=uri).one_or_none()
            mtime_dt = datetime.fromtimestamp(mtime, tz=UTC) if mtime else None
            raw_hash = (
                source_sha256
                if isinstance(source_sha256, (bytes, bytearray))
                else (bytes.fromhex(source_sha256) if source_sha256 else None)
            )
            content_hash = (
                content_sha256
                if isinstance(content_sha256, (bytes, bytearray))
                else (bytes.fromhex(content_sha256) if content_sha256 else b"")
            )
            c_class = CorpusClass(corpus_class) if corpus_class else src.default_class
            t_tier = TrustTier(trust_tier) if trust_tier else src.default_trust

            if doc is None:
                doc = Document(source_id=src.id, uri=uri)
                session.add(doc)

            doc.corpus_class = c_class
            doc.trust_tier = t_tier
            doc.title = title or None
            doc.mime = None
            doc.lang = lang or None
            doc.byte_size = byte_size
            doc.mtime = mtime_dt
            doc.source_sha256 = raw_hash
            doc.content_sha256 = content_hash
            doc.extractor = extractor
            doc.extractor_version = extractor_version or "1"
            doc.chunker = chunker or None
            doc.content = content or None
            doc.meta = meta or {}
            doc.state = IngestState.OK
            doc.error = None
            doc.ingested_at = datetime.now(tz=UTC)
            session.flush()

            # Replace authors
            session.query(DocumentAuthor).filter_by(document_id=doc.id).delete()
            seen_authors: set[tuple[int, str]] = set()
            for auth in authors:
                if not auth.name:
                    continue
                author_obj = get_or_create_author(
                    session,
                    auth.name,
                    identities=auth.identities,
                    is_self=auth.is_self,
                )
                role_str = auth.role or "author"
                key = (author_obj.id, role_str)
                if key in seen_authors:
                    continue
                seen_authors.add(key)
                session.add(
                    DocumentAuthor(
                        document_id=doc.id,
                        author_id=author_obj.id,
                        role=AuthorRole(role_str),
                        confidence=auth.confidence or 1.0,
                        evidence=auth.evidence or None,
                    )
                )

            # Replace chunks
            session.query(Chunk).filter_by(document_id=doc.id).delete()
            session.flush()
            for c in chunks:
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

            if run_id:
                session.execute(pg_insert(IngestSeen).values(run_id=run_id, uri=uri).on_conflict_do_nothing())
            session.commit()
            return len(chunks)

    def finalize_session(
        self,
        run_id: int,
        completed: bool,
        seen: int,
        indexed: int,
        skipped: int,
        failed: int,
        placeholders: int,
        materialized: int,
        materialized_bytes: int,
        errors: list[str],
    ) -> None:
        from garage_rag.db.models import IngestRun

        with self.factory() as session:
            run = session.get(IngestRun, run_id)
            if run is not None:
                run.finished_at = datetime.now(tz=UTC)
                run.completed = completed
                run.seen_count = seen
                run.indexed_count = indexed
                run.skipped_count = skipped
                run.failed_count = failed
                run.placeholder_count = placeholders
                run.materialized_count = materialized
                run.materialized_bytes = materialized_bytes
                if errors:
                    run.error = "; ".join(errors[:5])[:4000]
            session.commit()


class GrpcIngestStorageGateway(IngestStorageGateway):
    """Facade storage gateway that routes all database mutations through the gRPC server."""

    def __init__(self, client: Any) -> None:
        self.client = client

    def list_enabled_sources(self) -> list[str]:
        resp = self.client.list_sources()
        return [s.slug for s in resp.sources if s.enabled]

    def begin_session(self, source_slug: str, include_code: bool = False) -> SourceContext:
        from garage_rag.proto.garage_pb2 import BeginIngestSessionRequest

        req = BeginIngestSessionRequest(source_slug=source_slug, include_code=include_code)
        resp = self.client.begin_ingest_session(req)
        return SourceContext(
            source_id=resp.source_id,
            slug=resp.slug,
            root=Path(resp.root),
            default_class=CorpusClass(resp.default_class),
            default_trust=TrustTier(resp.default_trust),
            allow_cloud_enrichment=resp.allow_cloud_enrichment,
            run_id=resp.run_id,
            # BeginIngestSessionResponse carries no ``kind`` field, so a gRPC-backed
            # context always reports "filesystem" until the proto grows one.
            kind=getattr(resp, "kind", "") or "filesystem",
            source_slugs=list(resp.source_slugs),
        )

    def persist_scan(self, source_slug: str, scan_result: ScanResult) -> None:
        from garage_rag.proto.garage_pb2 import PersistScanRequest

        req = PersistScanRequest(
            source_slug=source_slug,
            item_count=scan_result.item_count,
            item_type=scan_result.item_type,
            duration_seconds=scan_result.duration_seconds,
            details=scan_result.details or {},
            error=scan_result.error or "",
        )
        self.client.persist_scan(req)

    def check_stat(self, source_slug: str, uri: str) -> ExistingDocStat:
        from garage_rag.proto.garage_pb2 import CheckDocumentStatRequest

        req = CheckDocumentStatRequest(source_slug=source_slug, uri=uri)
        resp = self.client.check_document_stat(req)
        return ExistingDocStat(
            exists=resp.exists,
            byte_size=resp.byte_size,
            mtime=resp.mtime,
            content_sha256=resp.content_sha256,
            chunker=resp.chunker,
            state=resp.state,
            source_sha256=resp.source_sha256,
        )

    def record_placeholder(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        mtime: float,
        title: str,
        error: str = "",
    ) -> None:
        from garage_rag.proto.garage_pb2 import PersistDocumentRequest

        req = PersistDocumentRequest(
            run_id=run_id,
            source_slug=source_slug,
            uri=uri,
            action="placeholder",
            title=title,
            mtime=mtime,
            error=error,
        )
        self.client.persist_document(req)

    def record_extract_failed(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        error: str,
    ) -> None:
        from garage_rag.proto.garage_pb2 import PersistDocumentRequest

        req = PersistDocumentRequest(
            run_id=run_id,
            source_slug=source_slug,
            uri=uri,
            action="extract_failed",
            error=error,
        )
        self.client.persist_document(req)

    def record_rejected(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
    ) -> None:
        from garage_rag.proto.garage_pb2 import PersistDocumentRequest

        req = PersistDocumentRequest(
            run_id=run_id,
            source_slug=source_slug,
            uri=uri,
            action="rejected",
        )
        self.client.persist_document(req)

    def record_seen(self, run_id: int, source_slug: str, uri: str) -> None:
        from garage_rag.proto.garage_pb2 import PersistDocumentRequest

        req = PersistDocumentRequest(run_id=run_id, source_slug=source_slug, uri=uri, action="seen")
        self.client.persist_document(req)

    def refresh_metadata(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        byte_size: int,
        mtime: float,
        source_sha256: str | bytes,
        corpus_class: str,
        trust_tier: str,
    ) -> None:
        from garage_rag.proto.garage_pb2 import PersistDocumentRequest

        src_sha = source_sha256.hex() if isinstance(source_sha256, (bytes, bytearray)) else (source_sha256 or "")
        req = PersistDocumentRequest(
            run_id=run_id,
            source_slug=source_slug,
            uri=uri,
            action="refresh_metadata",
            byte_size=byte_size,
            mtime=mtime,
            source_sha256=src_sha,
            corpus_class=corpus_class,
            trust_tier=trust_tier,
        )
        self.client.persist_document(req)

    def replace_document(
        self,
        run_id: int,
        source_slug: str,
        uri: str,
        title: str | None,
        lang: str | None,
        byte_size: int,
        mtime: float,
        source_sha256: str | None,
        content_sha256: str,
        extractor: str,
        extractor_version: str,
        chunker: str | None,
        content: str | None,
        meta: dict[str, Any],
        corpus_class: str,
        trust_tier: str,
        authors: list[AuthorPayload],
        chunks: list[ChunkPayload],
    ) -> int:
        from garage_rag.proto.garage_pb2 import (
            DocumentAuthorPayload,
            DocumentChunkPayload,
            PersistDocumentRequest,
        )

        author_payloads = [
            DocumentAuthorPayload(
                name=a.name,
                role=a.role,
                confidence=a.confidence,
                evidence=a.evidence or "",
                identities=a.identities or {},
                is_self=a.is_self,
            )
            for a in authors
        ]

        chunk_payloads = [
            DocumentChunkPayload(
                ord=c.ord,
                text=c.text,
                token_count=c.token_count or 0,
                char_start=c.char_start or 0,
                char_end=c.char_end or 0,
                heading_path=c.heading_path or "",
                chunk_sha256=(
                    c.chunk_sha256.hex()
                    if isinstance(c.chunk_sha256, (bytes, bytearray))
                    else str(c.chunk_sha256 or "")
                ),
                chunker=c.chunker or "",
            )
            for c in chunks
        ]

        src_sha = source_sha256.hex() if isinstance(source_sha256, (bytes, bytearray)) else (source_sha256 or "")
        cnt_sha = content_sha256.hex() if isinstance(content_sha256, (bytes, bytearray)) else str(content_sha256 or "")

        req = PersistDocumentRequest(
            run_id=run_id,
            source_slug=source_slug,
            uri=uri,
            action="replace",
            title=title or "",
            lang=lang or "",
            byte_size=byte_size,
            mtime=mtime,
            source_sha256=src_sha,
            content_sha256=cnt_sha,
            extractor=extractor,
            extractor_version=extractor_version,
            chunker=chunker or "",
            content=content or "",
            meta_json=json.dumps(meta) if meta else "{}",
            corpus_class=corpus_class,
            trust_tier=trust_tier,
            authors=author_payloads,
            chunks=chunk_payloads,
        )
        resp = self.client.persist_document(req)
        return resp.chunks_written

    def finalize_session(
        self,
        run_id: int,
        completed: bool,
        seen: int,
        indexed: int,
        skipped: int,
        failed: int,
        placeholders: int,
        materialized: int,
        materialized_bytes: int,
        errors: list[str],
    ) -> None:
        from garage_rag.proto.garage_pb2 import FinalizeIngestSessionRequest

        req = FinalizeIngestSessionRequest(
            run_id=run_id,
            completed=completed,
            seen_count=seen,
            indexed_count=indexed,
            skipped_count=skipped,
            failed_count=failed,
            placeholder_count=placeholders,
            materialized_count=materialized,
            materialized_bytes=materialized_bytes,
            errors=errors,
        )
        self.client.finalize_ingest_session(req)


def get_storage_gateway(
    session_factory: Callable[[], Any] | None = None,
    gateway: IngestStorageGateway | None = None,
    grpc_client: Any | None = None,
    grpc_host: str | None = None,
    grpc_port: int | None = None,
) -> IngestStorageGateway:
    """Obtain the configured IngestStorageGateway."""
    if gateway is not None:
        return gateway

    if session_factory is not None:
        return SqlAlchemyIngestStorageGateway(session_factory)

    if grpc_client is not None:
        return GrpcIngestStorageGateway(grpc_client)

    # Check environment variables or explicit port for gRPC
    env_port = os.environ.get("GARAGE_GRPC_PORT")
    env_host = os.environ.get("GARAGE_GRPC_HOST", "127.0.0.1")

    port = grpc_port or (int(env_port) if env_port else None)
    host = grpc_host or env_host

    if port:
        # Imported here, not at module scope: garage_rag.service depends on
        # ingest, so a top-level import would be a cycle.
        # gazelle:ignore garage_rag.service.client
        from garage_rag.service.client import GarageClient

        client = GarageClient(host=host, port=port, in_process=False)
        return GrpcIngestStorageGateway(client)

    # Fallback to direct DB engine session factory
    from garage_rag.db.engine import get_session_factory

    return SqlAlchemyIngestStorageGateway(get_session_factory())
