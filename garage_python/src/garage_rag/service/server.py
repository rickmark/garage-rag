"""gRPC Server implementation for GarageService."""

from __future__ import annotations

import os
import signal
import sys
import threading
import time
from concurrent import futures
from typing import Optional

import grpc

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    PingRequest,
    PingResponse,
    StatusRequest,
    StatusResponse,
    StopRequest,
    StopResponse,
)
from garage_rag.proto.garage_pb2_grpc import (
    GarageServiceServicer,
    add_GarageServiceServicer_to_server,
)
from garage_rag.service.executor import CommandExecutor, default_executor


class GarageRpcServicer(GarageServiceServicer):
    """gRPC Servicer implementing GarageService."""

    def __init__(self, executor: Optional[CommandExecutor] = None, stop_event: Optional[threading.Event] = None) -> None:
        self.executor = executor or default_executor
        self.stop_event = stop_event or threading.Event()

    def ExecuteCommand(self, request: CommandRequest, context: grpc.ServicerContext):
        """Execute a command request and stream CommandStatus events back to caller."""
        for status in self.executor.execute_command(request):
            yield status

    def Ping(self, request: PingRequest, context: grpc.ServicerContext) -> PingResponse:
        """Ping / Healthcheck."""
        return PingResponse(
            message=request.message or "pong",
            timestamp=int(time.time()),
        )

    def GetStatus(self, request: StatusRequest, context: grpc.ServicerContext) -> StatusResponse:
        """Retrieve server and database status."""
        from garage_rag.cli import get_version

        db_status = "unknown"
        try:
            from garage_rag.db.engine import check_connection
            db_status = "connected" if check_connection() else "disconnected"
        except Exception as e:
            db_status = f"error: {e}"

        return StatusResponse(
            version=get_version(),
            is_ready=True,
            pid=os.getpid(),
            db_status=db_status,
            server_type="grpc",
        )

    def Stop(self, request: StopRequest, context: grpc.ServicerContext) -> StopResponse:
        """Trigger graceful shutdown of the server."""
        self.stop_event.set()
        return StopResponse(success=True)


def create_grpc_server(
    host: str = "127.0.0.1",
    port: int = 50051,
    max_workers: int = 10,
    executor: Optional[CommandExecutor] = None,
    stop_event: Optional[threading.Event] = None,
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
    stop_event: Optional[threading.Event] = None,
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
