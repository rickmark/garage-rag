"""Service package for gRPC, in-process execution, and macOS XPC."""

from garage_rag.service.client import GarageClient, run_command_in_process
from garage_rag.service.executor import CommandExecutor, default_executor
from garage_rag.service.server import (
    GarageRpcServicer,
    create_grpc_server,
    serve_grpc,
)
from garage_rag.service.xpc import (
    PeerAuthenticator,
    XpcServiceServer,
    serve_xpc,
)

__all__ = [
    "CommandExecutor",
    "GarageClient",
    "GarageRpcServicer",
    "PeerAuthenticator",
    "XpcServiceServer",
    "create_grpc_server",
    "default_executor",
    "run_command_in_process",
    "serve_grpc",
    "serve_xpc",
]
