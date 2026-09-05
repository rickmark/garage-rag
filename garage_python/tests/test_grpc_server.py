"""Tests for gRPC Server and live RPC calls."""

from __future__ import annotations

import threading
import time
import grpc
import pytest

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    PingRequest,
    StatusRequest,
    StatusType,
    StopRequest,
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
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.GetStatus(StatusRequest())
        assert response.is_ready is True
        assert response.server_type == "grpc"
        assert response.pid > 0
        assert len(response.version) > 0


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


def test_grpc_stop(grpc_server):
    port, servicer = grpc_server
    assert not servicer.stop_event.is_set()
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        res = stub.Stop(StopRequest(reason="test"))
        assert res.success is True
    assert servicer.stop_event.is_set()
