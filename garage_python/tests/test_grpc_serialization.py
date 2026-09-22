"""Tests for dedicated gRPC RPC methods and client in-process execution."""

from __future__ import annotations

import json
from unittest.mock import patch

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    SearchRequest,
    StatusType,
)
from garage_rag.service.client import GarageClient, run_command_in_process
from garage_rag.service.executor import CommandExecutor


def test_dedicated_protobuf_messages():
    """Verify dedicated request and response protobufs serialize and deserialize properly."""
    search_req = SearchRequest(
        query="neural network",
        limit=5,
        mode="hybrid",
        model="bge-m3",
        corpus_classes=["document", "code"],
        trust_tiers=["authored"],
        sources=["docs"],
        author="rick",
        full=True,
    )
    serialized = search_req.SerializeToString()
    deserialized = SearchRequest()
    deserialized.ParseFromString(serialized)
    assert deserialized.query == "neural network"
    assert deserialized.limit == 5
    assert deserialized.mode == "hybrid"
    assert deserialized.model == "bge-m3"
    assert list(deserialized.corpus_classes) == ["document", "code"]
    assert list(deserialized.trust_tiers) == ["authored"]
    assert list(deserialized.sources) == ["docs"]
    assert deserialized.author == "rick"
    assert deserialized.full is True


def test_client_in_process_version():
    """Verify GarageClient.get_version() runs in-process with protobuf serialization."""
    client = GarageClient(in_process=True)
    resp = client.get_version()
    assert resp.version
    assert len(resp.version) > 0


def test_client_in_process_ping():
    """Verify GarageClient.ping() returns pong and timestamp."""
    client = GarageClient(in_process=True)
    resp = client.ping("test ping")
    assert resp.message == "test ping"
    assert resp.timestamp > 0


def test_client_in_process_status():
    """Verify GarageClient.get_status() returns server details."""
    client = GarageClient(in_process=True)
    # Readiness is derived from a live DB probe; mock that boundary.
    with (
        patch("garage_rag.db.engine.get_engine"),
        patch("garage_rag.db.migrate.has_pending_migrations", return_value=False),
    ):
        resp = client.get_status()
    assert resp.is_ready is True
    assert resp.pid > 0
    assert resp.version


def test_client_in_process_config_show():
    """Verify GarageClient.config_show() returns json config."""
    client = GarageClient(in_process=True)
    resp = client.config_show()
    assert resp.config_json
    data = json.loads(resp.config_json)
    assert isinstance(data, dict)


def test_client_in_process_mcp_status():
    """Verify GarageClient.mcp_status() returns target clients."""
    client = GarageClient(in_process=True)
    resp = client.mcp_status()
    assert len(resp.clients) > 0
    client_keys = [c.key for c in resp.clients]
    assert "project" in client_keys


def test_executor_empty_command():
    """Empty command args return error status."""
    executor = CommandExecutor()
    req = CommandRequest(argv=[])
    statuses = list(executor.execute_command(req))
    assert len(statuses) == 1
    assert statuses[0].type == StatusType.STATUS_ERROR
    assert statuses[0].exit_code == 1


def test_in_process_version_command():
    """Executing version command in-process yields started, output, and completed statuses."""
    statuses = list(run_command_in_process(["version"]))
    assert len(statuses) >= 2
    types = [s.type for s in statuses]
    assert StatusType.STATUS_STARTED in types
    assert StatusType.STATUS_COMPLETED in types

    outputs = [s.stdout for s in statuses if s.stdout]
    combined_output = "".join(outputs)
    assert "garage v" in combined_output

    final_status = statuses[-1]
    assert final_status.type == StatusType.STATUS_COMPLETED
    assert final_status.exit_code == 0


def test_client_execute_command_sends_only_argv():
    """The request must not carry the caller's environment (database URLs, tokens)."""
    captured: list[CommandRequest] = []

    class _RecordingServicer:
        def ExecuteCommand(self, request, context):
            captured.append(request)
            return iter(())

    client = GarageClient(in_process=True, servicer=_RecordingServicer())  # type: ignore[arg-type]
    list(client.execute_command(["version"]))
    assert len(captured) == 1
    assert list(captured[0].argv) == ["version"]
    assert captured[0].cwd == ""
    assert dict(captured[0].env) == {}


def test_client_close_is_idempotent_and_context_managed():
    """close() releases the channel; the client is usable as a context manager."""
    with GarageClient(host="127.0.0.1", port=1, in_process=False) as client:
        stub = client._get_stub()
        assert stub is client._get_stub()
        assert client._channel is not None
    assert client._channel is None
    assert client._stub is None
    client.close()  # second close is a no-op
