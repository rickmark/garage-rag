"""Tests for IngestStorageGateway and gRPC Ingest Database Facade."""

from __future__ import annotations

import threading
from pathlib import Path
from unittest.mock import MagicMock, patch
import pytest

from garage_rag.db.models import CorpusClass, IngestState, Source, TrustTier
from garage_rag.ingest.gateway import (
    AuthorPayload,
    ChunkPayload,
    ExistingDocStat,
    GrpcIngestStorageGateway,
    SqlAlchemyIngestStorageGateway,
    get_storage_gateway,
)
from garage_rag.ingest.pipeline import ingest_source
from garage_rag.ingest.scanner import SourceScanResult
from garage_rag.proto.garage_pb2 import (
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    PersistScanResponse,
)
from garage_rag.service.client import GarageClient
from garage_rag.service.server import GarageRpcServicer, create_grpc_server


@pytest.fixture
def grpc_server():
    """Start an in-memory / local gRPC server on an ephemeral port."""
    stop_event = threading.Event()
    server, servicer = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop_event)
    bound_port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield bound_port, servicer
    server.stop(grace=None)


def test_grpc_database_facade_servicer_methods():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    mock_source = MagicMock(spec=Source)
    mock_source.id = 101
    mock_source.slug = "facade-test-slug"
    mock_source.root = "/tmp/test"
    mock_source.kind = "filesystem"
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED
    mock_source.allow_cloud_enrichment = False

    with patch("garage_rag.db.engine.session_scope") as mock_scope, \
         patch("garage_rag.attribute.resolver.ensure_self_author"):
        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_source
        mock_session.query.return_value.filter_by.return_value.all.return_value = [mock_source]
        mock_session.query.return_value.order_by.return_value.all.return_value = [mock_source]
        mock_scope.return_value.__enter__.return_value = mock_session

        # 1. BeginIngestSession
        begin_req = BeginIngestSessionRequest(source_slug="facade-test-slug")
        begin_resp = servicer.BeginIngestSession(begin_req, mock_context)
        assert begin_resp.source_id == 101
        assert begin_resp.slug == "facade-test-slug"
        assert begin_resp.root == "/tmp/test"

        # 2. PersistScan
        with patch("garage_rag.ingest.scanner.persist_scan_result") as mock_persist_scan:
            scan_req = PersistScanRequest(
                source_slug="facade-test-slug",
                item_count=5,
                item_type="files",
                duration_seconds=0.12,
            )
            scan_resp = servicer.PersistScan(scan_req, mock_context)
            assert scan_resp.success is True
            mock_persist_scan.assert_called_once()

        # 3. CheckDocumentStat
        mock_doc = MagicMock()
        mock_doc.byte_size = 1234
        mock_doc.mtime = None
        mock_doc.source_sha256 = b"\xaa\xbb"
        mock_doc.content_sha256 = b"\xcc\xdd"
        mock_doc.chunker = "document:sentence"
        mock_doc.state = IngestState.OK

        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_doc
        stat_req = CheckDocumentStatRequest(source_slug="facade-test-slug", uri="doc1.txt")
        stat_resp = servicer.CheckDocumentStat(stat_req, mock_context)
        assert stat_resp.exists is True
        assert stat_resp.byte_size == 1234
        assert stat_resp.source_sha256 == "aabb"
        assert stat_resp.content_sha256 == "ccdd"

        # 4. PersistDocument (action=replace)
        with patch("garage_rag.attribute.resolver.get_or_create_author") as mock_author:
            mock_auth_obj = MagicMock()
            mock_auth_obj.id = 55
            mock_author.return_value = mock_auth_obj

            doc_req = PersistDocumentRequest(
                run_id=1,
                source_slug="facade-test-slug",
                uri="doc1.txt",
                action="replace",
                title="Doc 1",
                byte_size=1234,
                mtime=1700000000.0,
                content_sha256="ccdd",
                extractor="text",
                extractor_version="1",
                chunker="document:sentence",
                content="Hello world content",
            )
            doc_resp = servicer.PersistDocument(doc_req, mock_context)
            assert doc_resp.success is True

        # 5. FinalizeIngestSession
        final_req = FinalizeIngestSessionRequest(
            run_id=1,
            completed=True,
            seen_count=10,
            indexed_count=8,
            skipped_count=2,
        )
        final_resp = servicer.FinalizeIngestSession(final_req, mock_context)
        assert final_resp.success is True


def test_grpc_ingest_storage_gateway():
    client = GarageClient(in_process=True)
    gateway = GrpcIngestStorageGateway(client)

    with patch.object(client, "begin_ingest_session") as mock_begin, \
         patch.object(client, "persist_scan") as mock_scan, \
         patch.object(client, "check_document_stat") as mock_stat, \
         patch.object(client, "persist_document") as mock_doc, \
         patch.object(client, "finalize_ingest_session") as mock_final:

        mock_begin.return_value = BeginIngestSessionResponse(
            source_id=1,
            slug="grpc-src",
            root="/tmp/src",
            default_class="document",
            default_trust="authored",
            allow_cloud_enrichment=False,
            run_id=42,
            source_slugs=["grpc-src"],
        )

        ctx = gateway.begin_session("grpc-src")
        assert ctx.source_id == 1
        assert ctx.slug == "grpc-src"
        assert ctx.run_id == 42
        assert ctx.default_class == CorpusClass.DOCUMENT
        assert ctx.default_trust == TrustTier.AUTHORED

        scan_result = SourceScanResult(
            source_slug="grpc-src",
            kind="filesystem",
            root=Path("/tmp/src"),
            item_count=10,
            item_type="files",
        )
        gateway.persist_scan("grpc-src", scan_result)
        mock_scan.assert_called_once()

        mock_stat.return_value = CheckDocumentStatResponse(
            exists=True,
            byte_size=500,
            mtime=1700000000.0,
            content_sha256="abc",
            chunker="test",
            state="OK",
            source_sha256="def",
        )
        stat = gateway.check_stat("grpc-src", "file.txt")
        assert stat.exists is True
        assert stat.byte_size == 500
        assert stat.content_sha256 == "abc"

        mock_doc.return_value = PersistDocumentResponse(success=True, chunks_written=3)
        written = gateway.replace_document(
            run_id=42,
            source_slug="grpc-src",
            uri="file.txt",
            title="File",
            lang="en",
            byte_size=500,
            mtime=1700000000.0,
            source_sha256="def",
            content_sha256="abc",
            extractor="text",
            extractor_version="1",
            chunker="test",
            content="test content",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[AuthorPayload(name="Author", role="author")],
            chunks=[ChunkPayload(ord=0, text="test content", chunk_sha256="123")],
        )
        assert written == 3

        gateway.finalize_session(
            run_id=42,
            completed=True,
            seen=1,
            indexed=1,
            skipped=0,
            failed=0,
            placeholders=0,
            materialized=0,
            materialized_bytes=0,
            errors=[],
        )
        mock_final.assert_called_once()


def test_ingest_source_with_grpc_gateway(tmp_path: Path):
    (tmp_path / "hello.txt").write_text("Hello from gRPC facade test", encoding="utf-8")

    client = GarageClient(in_process=True)
    gateway = GrpcIngestStorageGateway(client)

    with patch.object(client, "begin_ingest_session") as mock_begin, \
         patch.object(client, "persist_scan") as mock_scan, \
         patch.object(client, "check_document_stat") as mock_stat, \
         patch.object(client, "persist_document") as mock_doc, \
         patch.object(client, "finalize_ingest_session") as mock_final:

        mock_begin.return_value = BeginIngestSessionResponse(
            source_id=1,
            slug="mock-slug",
            root=str(tmp_path),
            default_class="document",
            default_trust="authored",
            allow_cloud_enrichment=False,
            run_id=10,
            source_slugs=["mock-slug"],
        )

        mock_stat.return_value = CheckDocumentStatResponse(exists=False)
        mock_doc.return_value = PersistDocumentResponse(success=True, chunks_written=1)
        mock_final.return_value = FinalizeIngestSessionResponse(success=True)

        counters, walk_stats, budget = ingest_source(
            source_slug="mock-slug",
            gateway=gateway,
        )

        assert counters.seen == 1
        assert counters.indexed == 1
        assert counters.chunks_written == 1
        mock_begin.assert_called_once()
        mock_scan.assert_called_once()
        mock_doc.assert_called_once()
        mock_final.assert_called_once()


def test_ingest_gateway_via_live_grpc_server(grpc_server, tmp_path: Path):
    port, servicer = grpc_server
    client = GarageClient(host="127.0.0.1", port=port, in_process=False)
    gateway = GrpcIngestStorageGateway(client)

    test_file = tmp_path / "doc.txt"
    test_file.write_text("Hello live gRPC ingest", encoding="utf-8")

    mock_source = MagicMock(spec=Source)
    mock_source.id = 1
    mock_source.slug = "live-grpc-src"
    mock_source.root = str(tmp_path)
    mock_source.kind = "filesystem"
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED
    mock_source.allow_cloud_enrichment = False

    with patch("garage_rag.db.engine.session_scope") as mock_scope, \
         patch("garage_rag.attribute.resolver.ensure_self_author"), \
         patch("garage_rag.ingest.scanner.persist_scan_result"), \
         patch("garage_rag.attribute.resolver.get_or_create_author") as mock_author:

        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_source
        mock_session.query.return_value.filter_by.return_value.all.return_value = [mock_source]
        mock_session.query.return_value.order_by.return_value.all.return_value = [mock_source]
        mock_scope.return_value.__enter__.return_value = mock_session

        mock_auth_obj = MagicMock()
        mock_auth_obj.id = 10
        mock_author.return_value = mock_auth_obj

        # 1. begin_session over live gRPC
        ctx = gateway.begin_session("live-grpc-src")
        assert ctx.source_id == 1
        assert ctx.slug == "live-grpc-src"

        # 2. persist_scan over live gRPC
        scan_result = SourceScanResult(
            source_slug="live-grpc-src",
            kind="filesystem",
            root=tmp_path,
            item_count=1,
            item_type="files",
        )
        gateway.persist_scan("live-grpc-src", scan_result)

        # 3. check_stat over live gRPC
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = None
        stat = gateway.check_stat("live-grpc-src", "doc.txt")
        assert stat.exists is False

        # 4. replace_document over live gRPC
        written = gateway.replace_document(
            run_id=ctx.run_id,
            source_slug="live-grpc-src",
            uri="doc.txt",
            title="Doc",
            lang="en",
            byte_size=len("Hello live gRPC ingest"),
            mtime=1700000000.0,
            source_sha256="11",
            content_sha256="22",
            extractor="text",
            extractor_version="1",
            chunker="test",
            content="Hello live gRPC ingest",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[AuthorPayload(name="Author", role="author")],
            chunks=[ChunkPayload(ord=0, text="Hello live gRPC ingest", chunk_sha256="33")],
        )
        assert written == 1

        # 5. finalize_session over live gRPC
        gateway.finalize_session(
            run_id=ctx.run_id,
            completed=True,
            seen=1,
            indexed=1,
            skipped=0,
            failed=0,
            placeholders=0,
            materialized=0,
            materialized_bytes=0,
            errors=[],
        )
