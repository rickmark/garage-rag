"""The ``GarageService`` gRPC server and its Python client."""

from garage_rag.service.client import GarageClient
from garage_rag.service.server import (
    GarageRpcServicer,
    create_grpc_server,
    serve_grpc,
)

__all__ = [
    "GarageClient",
    "GarageRpcServicer",
    "create_grpc_server",
    "serve_grpc",
]
