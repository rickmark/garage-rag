"""Client interfaces for executing Garage commands in-process, over gRPC, or over macOS XPC."""

from __future__ import annotations

import os
import sys
from typing import Iterator, List, Optional

import grpc

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.executor import CommandExecutor, default_executor
from garage_rag.service.xpc import (
    DEFAULT_XPC_SERVICE_NAME,
    XpcServiceServer,
)


def run_command_in_process(
    argv: list[str],
    executor: Optional[CommandExecutor] = None,
) -> Iterator[CommandStatus]:
    """Serialize command into CommandRequest protobuf and execute in-process, streaming CommandStatus."""
    exec_inst = executor or default_executor
    request = CommandRequest(
        argv=argv,
        cwd=os.getcwd(),
        env={k: v for k, v in os.environ.items() if isinstance(v, str)},
    )
    # Serialize to bytes and deserialize to guarantee gRPC wire fidelity
    serialized_bytes = request.SerializeToString()
    deserialized_request = CommandRequest()
    deserialized_request.ParseFromString(serialized_bytes)

    for status in exec_inst.execute_command(deserialized_request):
        # Roundtrip status through protobuf serialization as well
        status_bytes = status.SerializeToString()
        deserialized_status = CommandStatus()
        deserialized_status.ParseFromString(status_bytes)
        yield deserialized_status


def run_command_grpc(
    argv: list[str],
    host: str = "127.0.0.1",
    port: int = 50051,
) -> Iterator[CommandStatus]:
    """Execute command on a remote gRPC Garage server and stream CommandStatus responses."""
    server_address = f"{host}:{port}"
    with grpc.insecure_channel(server_address) as channel:
        stub = GarageServiceStub(channel)
        request = CommandRequest(
            argv=argv,
            cwd=os.getcwd(),
        )
        try:
            for status in stub.ExecuteCommand(request):
                yield status
        except grpc.RpcError as exc:
            yield CommandStatus(
                type=StatusType.STATUS_ERROR,
                exit_code=1,
                error_message=f"gRPC RPC Error: {exc.details() if hasattr(exc, 'details') else exc}",
            )


def execute_and_render_cli(
    argv: list[str],
    host: Optional[str] = None,
    port: Optional[int] = None,
    use_remote_grpc: bool = False,
) -> int:
    """Execute command serialized through gRPC pipeline and render streaming status/output to console."""
    if use_remote_grpc or (host and port):
        h = host or "127.0.0.1"
        p = port or 50051
        status_stream = run_command_grpc(argv, host=h, port=p)
    else:
        status_stream = run_command_in_process(argv)

    exit_code = 0
    for status in status_stream:
        if status.stdout:
            sys.stdout.write(status.stdout)
            sys.stdout.flush()
        if status.stderr:
            sys.stderr.write(status.stderr)
            sys.stderr.flush()
        if status.type == StatusType.STATUS_ERROR:
            exit_code = status.exit_code or 1
        elif status.type == StatusType.STATUS_COMPLETED:
            if exit_code == 0:
                exit_code = status.exit_code

    return exit_code
