"""Tests for the EnrichFacts gRPC RPC."""

from __future__ import annotations

import contextlib
from unittest.mock import MagicMock, patch

import grpc

from garage_rag.db.models import Document
from garage_rag.proto.garage_pb2 import EnrichFactsRequest
from garage_rag.service.server import GarageRpcServicer


def _mock_document(doc_id, uri):
    doc = MagicMock(spec=Document)
    doc.id = doc_id
    doc.uri = uri
    return doc


def test_enrich_facts_single_document_by_id():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()
    document = _mock_document(5, "/tmp/one.md")

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.return_value = document

        with patch(
            "garage_rag.enrich.facts.extract_and_store_facts", return_value=[MagicMock(), MagicMock()]
        ) as mock_extract:
            statuses = list(servicer.EnrichFacts(EnrichFactsRequest(document_id=5), mock_context))

    assert len(statuses) == 1
    assert statuses[0].document_id == 5
    assert statuses[0].total == 1
    assert statuses[0].processed == 1
    assert statuses[0].facts_extracted == 2
    assert statuses[0].is_complete is True
    mock_extract.assert_called_once()
    mock_session.commit.assert_called_once()


def test_enrich_facts_document_id_not_found_aborts():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()
    mock_context.abort.side_effect = grpc.RpcError()

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.return_value = None

        with contextlib.suppress(grpc.RpcError):
            list(servicer.EnrichFacts(EnrichFactsRequest(document_id=999), mock_context))

    mock_context.abort.assert_called_once()
    assert mock_context.abort.call_args[0][0] == grpc.StatusCode.NOT_FOUND


def test_enrich_facts_all_documents_for_source_streams_one_status_each():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()
    docs = [_mock_document(1, "/a.md"), _mock_document(2, "/b.md")]

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        joined = mock_session.query.return_value.join.return_value
        joined.filter.return_value.order_by.return_value.all.return_value = docs

        with patch(
            "garage_rag.enrich.facts.extract_and_store_facts",
            side_effect=[[MagicMock()], [MagicMock(), MagicMock()]],
        ):
            statuses = list(servicer.EnrichFacts(EnrichFactsRequest(source="notes"), mock_context))

    assert len(statuses) == 2
    assert statuses[0].facts_extracted == 1
    assert statuses[0].is_complete is False
    assert statuses[1].facts_extracted == 2
    assert statuses[1].is_complete is True
    assert statuses[1].progress == 1.0


def test_enrich_facts_no_documents_yields_single_complete_status():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        joined = mock_session.query.return_value.join.return_value
        joined.filter.return_value.order_by.return_value.all.return_value = []

        statuses = list(servicer.EnrichFacts(EnrichFactsRequest(source="empty-source"), mock_context))

    assert len(statuses) == 1
    assert statuses[0].total == 0
    assert statuses[0].is_complete is True


def test_enrich_facts_records_failure_and_continues():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()
    docs = [_mock_document(1, "/a.md"), _mock_document(2, "/b.md")]

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        joined = mock_session.query.return_value.join.return_value
        joined.filter.return_value.order_by.return_value.all.return_value = docs

        with patch(
            "garage_rag.enrich.facts.extract_and_store_facts",
            side_effect=[RuntimeError("boom"), [MagicMock()]],
        ):
            statuses = list(servicer.EnrichFacts(EnrichFactsRequest(source="notes"), mock_context))

    assert len(statuses) == 2
    assert statuses[0].failed == 1
    assert statuses[0].error_message == "boom"
    assert statuses[1].failed == 1
    assert statuses[1].processed == 1
    assert statuses[1].is_complete is True
    mock_session.rollback.assert_called_once()


def test_enrich_facts_defaults_to_the_configured_backend():
    """Unset request fields fall back to facts.model / facts.provider."""
    from garage_rag.config import Settings, reset_settings, set_settings

    servicer = GarageRpcServicer()
    document = _mock_document(5, "/tmp/one.md")
    set_settings(Settings(fact_model="phi-4-mini", fact_provider="ollama"))
    try:
        with patch("garage_rag.db.engine.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            mock_session.get.return_value = document
            with patch("garage_rag.enrich.facts.extract_and_store_facts", return_value=[]) as mock_extract:
                list(servicer.EnrichFacts(EnrichFactsRequest(document_id=5), MagicMock()))
                assert mock_extract.call_args.kwargs == {"model_id": "phi-4-mini", "provider": "ollama"}

                mock_extract.reset_mock()
                request = EnrichFactsRequest(document_id=5, model_id="gemma2-2b", provider="llama_xpc")
                list(servicer.EnrichFacts(request, MagicMock()))
                assert mock_extract.call_args.kwargs == {"model_id": "gemma2-2b", "provider": "llama_xpc"}
    finally:
        reset_settings()
