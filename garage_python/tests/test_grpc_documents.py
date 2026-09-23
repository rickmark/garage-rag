"""Tests for the Documents & Chunks gRPC RPCs (ListDocuments, GetDocument)."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import grpc
import pytest

from garage_rag.db.models import Chunk, CorpusClass, Document, Fact, IngestState, TrustTier
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

        document_query = MagicMock()
        joined = document_query.join.return_value
        joined.with_entities.return_value.scalar.return_value = 1
        joined.order_by.return_value.offset.return_value.limit.return_value.all.return_value = [document]
        # Separate source-slug lookup query, keyed by document id.
        joined.filter.return_value.all.return_value = [(document.id, "notes")]

        chunk_count_query = MagicMock()
        chunk_count_query.filter.return_value.group_by.return_value.all.return_value = [(document.id, 3)]

        fact_count_query = MagicMock()
        fact_count_query.filter.return_value.group_by.return_value.all.return_value = [(document.id, 5)]

        def query_side_effect(*entities):
            model = entities[0]
            if model is Document or model is Document.id:
                return document_query
            if model is Chunk.document_id:
                return chunk_count_query
            if model is Fact.document_id:
                return fact_count_query
            raise AssertionError(f"unexpected query entities: {entities}")

        mock_session.query.side_effect = query_side_effect

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
    assert summary.fact_count == 5


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

    fact = MagicMock()
    fact.id = 77
    fact.ord = 0
    fact.fact = "The sky is blue."
    fact.fact_class = "fact"
    fact.attributes = {"confidence": "high"}
    fact.char_start = 0
    fact.char_end = 16
    fact.extractor = "langextract"

    source = MagicMock(slug="notes")

    chunk_query = MagicMock()
    chunk_query.filter.return_value.order_by.return_value.all.return_value = [chunk]

    fact_query = MagicMock()
    fact_query.filter.return_value.order_by.return_value.all.return_value = [fact]

    def query_side_effect(model):
        if model is Chunk:
            return chunk_query
        if model is Fact:
            return fact_query
        raise AssertionError(f"unexpected query for {model}")

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.side_effect = lambda model, _id: document if model is Document else source
        mock_session.query.side_effect = query_side_effect

        response = servicer.GetDocument(GetDocumentRequest(document_id=document.id), mock_context)

    assert response.document.id == document.id
    assert response.document.title == "Doc Title"
    assert response.document.source_slug == "notes"
    assert len(response.chunks) == 1
    assert response.chunks[0].text == "hello world"
    assert response.chunks[0].heading_path == "Intro"
    assert response.chunks[0].token_count == 2
    assert len(response.facts) == 1
    assert response.facts[0].fact == "The sky is blue."
    assert response.facts[0].fact_class == "fact"
    assert response.facts[0].extractor == "langextract"


def test_grpc_get_document_not_found():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()
    # A real ServicerContext.abort() raises and never returns; mirror that so the
    # handler cannot fall through to dereference the missing document.
    mock_context.abort.side_effect = grpc.RpcError("aborted")

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.return_value = None

        with pytest.raises(grpc.RpcError):
            servicer.GetDocument(GetDocumentRequest(document_id=999), mock_context)

    mock_context.abort.assert_called_once()
    assert mock_context.abort.call_args.args[0] == grpc.StatusCode.NOT_FOUND
