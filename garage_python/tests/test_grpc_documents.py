"""Tests for the Documents & Chunks gRPC RPCs (ListDocuments, GetDocument)."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import grpc

from garage_rag.db.models import CorpusClass, Document, IngestState, TrustTier
from garage_rag.proto.garage_pb2 import GetDocumentRequest, ListDocumentsRequest
from garage_rag.service.server import GarageRpcServicer


def _mock_document(doc_id=1, source_slug="notes", title="Doc Title", uri="/tmp/doc.md"):
    document = MagicMock()
    document.id = doc_id
    document.uri = uri
    document.title = title
    document.corpus_class = CorpusClass.DOCUMENT
    document.trust_tier = TrustTier.AUTHORED
    document.mime = "text/markdown"
    document.lang = "en"
    document.byte_size = 1234
    document.extractor = "markdown"
    document.extractor_version = "1"
    document.chunker = "heading"
    document.meta = {"k": "v"}
    document.state = IngestState.OK
    document.error = None
    document.ingested_at = datetime(2024, 1, 1, tzinfo=UTC)
    document.source = MagicMock(slug=source_slug)
    document.authors = []
    return document


def test_grpc_list_documents_empty_filters():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    document = _mock_document()

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session

        joined = mock_session.query.return_value.join.return_value
        joined.with_entities.return_value.scalar.return_value = 1
        joined.order_by.return_value.offset.return_value.limit.return_value.all.return_value = [document]

        # Separate chunk-count lookup query, keyed by document id.
        mock_session.query.return_value.filter.return_value.group_by.return_value.all.return_value = [
            (document.id, 3)
        ]
        # Separate source-slug lookup query, keyed by document id.
        joined.filter.return_value.all.return_value = [(document.id, "notes")]

        response = servicer.ListDocuments(ListDocumentsRequest(), mock_context)

    assert response.total_count == 1
    assert len(response.documents) == 1
    summary = response.documents[0]
    assert summary.id == document.id
    assert summary.title == "Doc Title"
    assert summary.source_slug == "notes"
    assert summary.corpus_class == "document"
    assert summary.trust_tier == "authored"
    assert summary.chunk_count == 3


def test_grpc_get_document_found():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    document = _mock_document()

    chunk = MagicMock()
    chunk.id = 55
    chunk.ord = 0
    chunk.text = "hello world"
    chunk.token_count = 2
    chunk.char_start = 0
    chunk.char_end = 11
    chunk.heading_path = "Intro"

    source = MagicMock(slug="notes")

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.side_effect = lambda model, _id: document if model is Document else source
        mock_session.query.return_value.filter.return_value.order_by.return_value.all.return_value = [chunk]

        response = servicer.GetDocument(GetDocumentRequest(document_id=document.id), mock_context)

    assert response.document.id == document.id
    assert response.document.title == "Doc Title"
    assert response.document.source_slug == "notes"
    assert len(response.chunks) == 1
    assert response.chunks[0].text == "hello world"
    assert response.chunks[0].heading_path == "Intro"
    assert response.chunks[0].token_count == 2


def test_grpc_get_document_not_found():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.return_value = None

        response = servicer.GetDocument(GetDocumentRequest(document_id=999), mock_context)

    mock_context.set_code.assert_called_once_with(grpc.StatusCode.NOT_FOUND)
    assert response.document.id == 0
