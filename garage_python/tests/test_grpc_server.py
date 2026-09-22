"""Tests for gRPC Server and live dedicated RPC calls."""

from __future__ import annotations

import json
import threading
import time
from unittest.mock import patch

import grpc
import pytest

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    ConfigPathRequest,
    ConfigShowRequest,
    GetEmbeddingBatchesRequest,
    McpStatusRequest,
    PingRequest,
    StatusRequest,
    StatusType,
    StopRequest,
    VersionRequest,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.server import create_grpc_server


@pytest.fixture
def grpc_server():
    """Start an in-memory / local gRPC server on an ephemeral port."""
    stop_event = threading.Event()
    # Port 0 lets OS assign an ephemeral available port
    server, servicer = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop_event)
    bound_port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield bound_port, servicer
    server.stop(grace=None)


def test_grpc_ping(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.Ping(PingRequest(message="hello garage"))
        assert response.message == "hello garage"
        assert response.timestamp > 0


def test_grpc_get_status(grpc_server):
    port, _ = grpc_server
    # The servicer runs in this process, so patching the DB boundary here applies to it.
    with (
        patch("garage_rag.db.engine.get_engine"),
        patch("garage_rag.db.migrate.has_pending_migrations", return_value=False),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        stub = GarageServiceStub(channel)
        response = stub.GetStatus(StatusRequest())
        assert response.is_ready is True
        assert response.db_status == "connected"
        assert response.server_type == "grpc"
        assert response.pid > 0
        assert len(response.version) > 0


def test_grpc_get_version(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.GetVersion(VersionRequest())
        assert response.version
        assert len(response.version) > 0


def test_grpc_config_show(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.ConfigShow(ConfigShowRequest(show_defaults=True))
        assert response.config_json
        data = json.loads(response.config_json)
        assert isinstance(data, dict)


def test_grpc_config_path(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.ConfigPath(ConfigPathRequest())
        assert len(response.candidate_paths) > 0


def test_grpc_mcp_status(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.McpStatus(McpStatusRequest())
        assert len(response.clients) > 0
        assert response.server_command


def test_grpc_execute_command_stream(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        req = CommandRequest(argv=["version"])
        statuses = list(stub.ExecuteCommand(req))
        assert len(statuses) >= 2
        types = [s.type for s in statuses]
        assert StatusType.STATUS_STARTED in types
        assert StatusType.STATUS_COMPLETED in types

        output_chunks = [s.stdout for s in statuses if s.stdout]
        assert "garage v" in "".join(output_chunks)


def test_grpc_execute_command_reports_nonzero_exit(grpc_server, tmp_path):
    """A command that ends with ``typer.Exit(code=1)`` must not be reported as success.

    ``config init`` refuses to overwrite an existing file and exits 1; in
    non-standalone mode Typer *returns* that code rather than raising, which the
    executor used to discard.
    """
    existing = tmp_path / "garage.json"
    existing.write_text("{}")
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        statuses = list(stub.ExecuteCommand(CommandRequest(argv=["config", "init", "--path", str(existing)])))
    final = statuses[-1]
    assert final.type == StatusType.STATUS_ERROR
    assert final.exit_code == 1
    assert StatusType.STATUS_COMPLETED not in [s.type for s in statuses]
    assert "already exists" in "".join(s.stdout for s in statuses)


def test_grpc_get_embedding_batches_unknown_model_is_not_found(grpc_server):
    """An unregistered model aborts with NOT_FOUND instead of an empty OK response."""
    port, _ = grpc_server
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.db.emb_tables.get_model", side_effect=LookupError("no model 'nope' registered")),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        stub = GarageServiceStub(channel)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.GetEmbeddingBatches(GetEmbeddingBatchesRequest(model_slug="nope", batch_size=8))
    assert excinfo.value.code() == grpc.StatusCode.NOT_FOUND
    assert "nope" in excinfo.value.details()


def test_grpc_get_embedding_batches_db_outage_is_an_error(grpc_server):
    """A database failure must surface as an RPC error, not as "nothing pending"."""
    port, _ = grpc_server
    with (
        patch("garage_rag.db.engine.session_scope", side_effect=RuntimeError("connection refused")),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        stub = GarageServiceStub(channel)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.GetEmbeddingBatches(GetEmbeddingBatchesRequest(model_slug="bge-m3"))
    assert excinfo.value.code() != grpc.StatusCode.OK


def test_grpc_stop(grpc_server):
    """Stop sets the event and, via the watcher in create_grpc_server, actually stops serving."""
    port, servicer = grpc_server
    assert not servicer.stop_event.is_set()
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        res = stub.Stop(StopRequest(reason="test"))
        assert res.success is True
    assert servicer.stop_event.is_set()

    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
            try:
                GarageServiceStub(channel).Ping(PingRequest(message="still there?"), timeout=0.5)
            except grpc.RpcError:
                break
        time.sleep(0.05)
    else:
        pytest.fail("server kept serving after the Stop RPC")
