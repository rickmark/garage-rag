"""Client interfaces for executing Garage dedicated RPC commands in-process, over gRPC, or over macOS XPC."""

from __future__ import annotations

import os
import sys
from typing import Any, Callable, Iterator, List, Optional

import grpc

from garage_rag.proto.garage_pb2 import (
    AddSourceRequest,
    AddSourceResponse,
    BackfillRequest,
    BackfillStatus,
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    CommandRequest,
    CommandStatus,
    ConfigImportSourcesRequest,
    ConfigImportSourcesResponse,
    ConfigInitRequest,
    ConfigInitResponse,
    ConfigPathRequest,
    ConfigPathResponse,
    ConfigSchemaRequest,
    ConfigSchemaResponse,
    ConfigShowRequest,
    ConfigShowResponse,
    DocumentAuthorPayload,
    DocumentChunkPayload,
    DropModelRequest,
    DropModelResponse,
    ExtractRequest,
    ExtractResponse,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    GetEmbeddingBatchesRequest,
    GetEmbeddingBatchesResponse,
    IngestRequest,
    IngestStatus,
    InitDbRequest,
    InitDbResponse,
    ListModelsRequest,
    ListModelsResponse,
    ListSourcesRequest,
    ListSourcesResponse,
    McpInstallRequest,
    McpInstallResponse,
    McpServeRequest,
    McpServeStatus,
    McpStatusRequest,
    McpStatusResponse,
    McpUninstallRequest,
    McpUninstallResponse,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    PersistScanResponse,
    PingRequest,
    PingResponse,
    ReconcileRequest,
    ReconcileResponse,
    RegisterModelRequest,
    RegisterModelResponse,
    RemoveSourceRequest,
    RemoveSourceResponse,
    ScanRequest,
    ScanResponse,
    SearchRequest,
    SearchResponse,
    SetDefaultModelRequest,
    SetDefaultModelResponse,
    StatsRequest,
    StatsResponse,
    StatusRequest,
    StatusResponse,
    StatusType,
    StopRequest,
    StopResponse,
    SyncRequest,
    SyncStatus,
    UpdateEmbeddingsRequest,
    UpdateEmbeddingsResponse,
    VersionRequest,
    VersionResponse,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.executor import CommandExecutor, default_executor
from garage_rag.service.server import GarageRpcServicer


class _InProcessServicerContext:
    """Mock servicer context for in-process direct RPC execution."""

    def __init__(self) -> None:
        self.code = grpc.StatusCode.OK
        self.details_msg = ""

    def abort(self, code: grpc.StatusCode, details: str):
        self.code = code
        self.details_msg = details
        raise RuntimeError(f"RPC Error ({code}): {details}")

    def set_code(self, code: grpc.StatusCode):
        self.code = code

    def set_details(self, details: str):
        self.details_msg = details


class GarageClient:
    """Client for interacting with Garage over dedicated gRPC RPC methods or in-process serialization."""

    def __init__(
        self,
        host: Optional[str] = None,
        port: Optional[int] = None,
        in_process: bool = True,
        servicer: Optional[GarageRpcServicer] = None,
    ) -> None:
        self.host = host or "127.0.0.1"
        self.port = port or 50051
        self.in_process = in_process and not (host and port)
        self.servicer = servicer or GarageRpcServicer()
        self._channel: Optional[grpc.Channel] = None
        self._stub: Optional[GarageServiceStub] = None

    def _get_stub(self) -> GarageServiceStub:
        if self._stub is None:
            server_address = f"{self.host}:{self.port}"
            self._channel = grpc.insecure_channel(server_address)
            self._stub = GarageServiceStub(self._channel)
        return self._stub

    def _roundtrip_proto(self, msg: Any, msg_cls: Any) -> Any:
        serialized = msg.SerializeToString()
        out = msg_cls()
        out.ParseFromString(serialized)
        return out

    def _invoke_unary(self, rpc_name: str, request: Any, response_cls: Any) -> Any:
        if self.in_process:
            req_copy = self._roundtrip_proto(request, type(request))
            ctx = _InProcessServicerContext()
            method = getattr(self.servicer, rpc_name)
            res = method(req_copy, ctx)
            return self._roundtrip_proto(res, response_cls)
        else:
            stub = self._get_stub()
            stub_method = getattr(stub, rpc_name)
            return stub_method(request)

    def _invoke_stream(self, rpc_name: str, request: Any, response_cls: Any) -> Iterator[Any]:
        if self.in_process:
            req_copy = self._roundtrip_proto(request, type(request))
            ctx = _InProcessServicerContext()
            method = getattr(self.servicer, rpc_name)
            for item in method(req_copy, ctx):
                yield self._roundtrip_proto(item, response_cls)
        else:
            stub = self._get_stub()
            stub_method = getattr(stub, rpc_name)
            for item in stub_method(request):
                yield item

    # -----------------------------------------------------------------------
    # RPC Methods
    # -----------------------------------------------------------------------

    def ping(self, message: str = "ping") -> PingResponse:
        req = PingRequest(message=message)
        return self._invoke_unary("Ping", req, PingResponse)

    def get_status(self) -> StatusResponse:
        req = StatusRequest()
        return self._invoke_unary("GetStatus", req, StatusResponse)

    def get_version(self) -> VersionResponse:
        req = VersionRequest()
        return self._invoke_unary("GetVersion", req, VersionResponse)

    def stop(self, reason: str = "") -> StopResponse:
        req = StopRequest(reason=reason)
        return self._invoke_unary("Stop", req, StopResponse)

    def search(self, request: SearchRequest) -> SearchResponse:
        return self._invoke_unary("Search", request, SearchResponse)

    def list_sources(self) -> ListSourcesResponse:
        req = ListSourcesRequest()
        return self._invoke_unary("ListSources", req, ListSourcesResponse)

    def add_source(self, request: AddSourceRequest) -> AddSourceResponse:
        return self._invoke_unary("AddSource", request, AddSourceResponse)

    def remove_source(self, slug: str, force: bool = False) -> RemoveSourceResponse:
        req = RemoveSourceRequest(slug=slug, force=force)
        return self._invoke_unary("RemoveSource", req, RemoveSourceResponse)

    def scan(self, request: ScanRequest) -> ScanResponse:
        return self._invoke_unary("Scan", request, ScanResponse)

    def ingest(self, request: IngestRequest) -> Iterator[IngestStatus]:
        return self._invoke_stream("Ingest", request, IngestStatus)

    def backfill(self, request: BackfillRequest) -> Iterator[BackfillStatus]:
        return self._invoke_stream("Backfill", request, BackfillStatus)

    def reconcile(self, request: ReconcileRequest) -> ReconcileResponse:
        return self._invoke_unary("Reconcile", request, ReconcileResponse)

    def register_model(self, request: RegisterModelRequest) -> RegisterModelResponse:
        return self._invoke_unary("RegisterModel", request, RegisterModelResponse)

    def list_models(self) -> ListModelsResponse:
        req = ListModelsRequest()
        return self._invoke_unary("ListModels", req, ListModelsResponse)

    def set_default_model(self, slug: str) -> SetDefaultModelResponse:
        req = SetDefaultModelRequest(slug=slug)
        return self._invoke_unary("SetDefaultModel", req, SetDefaultModelResponse)

    def drop_model(self, slug: str, force: bool = False) -> DropModelResponse:
        req = DropModelRequest(slug=slug, force=force)
        return self._invoke_unary("DropModel", req, DropModelResponse)

    def get_stats(self) -> StatsResponse:
        req = StatsRequest()
        return self._invoke_unary("GetStats", req, StatsResponse)

    def extract(self, request: ExtractRequest) -> ExtractResponse:
        return self._invoke_unary("Extract", request, ExtractResponse)

    def mcp_serve(self, request: McpServeRequest) -> Iterator[McpServeStatus]:
        return self._invoke_stream("McpServe", request, McpServeStatus)

    def mcp_install(self, request: McpInstallRequest) -> McpInstallResponse:
        return self._invoke_unary("McpInstall", request, McpInstallResponse)

    def mcp_uninstall(self, request: McpUninstallRequest) -> McpUninstallResponse:
        return self._invoke_unary("McpUninstall", request, McpUninstallResponse)

    def mcp_status(self) -> McpStatusResponse:
        req = McpStatusRequest()
        return self._invoke_unary("McpStatus", req, McpStatusResponse)

    def sync(self, request: SyncRequest) -> Iterator[SyncStatus]:
        return self._invoke_stream("Sync", request, SyncStatus)

    def init_db(self, schema_dir: str = "") -> InitDbResponse:
        req = InitDbRequest(schema_dir=schema_dir)
        return self._invoke_unary("InitDb", req, InitDbResponse)

    def config_init(self, request: ConfigInitRequest) -> ConfigInitResponse:
        return self._invoke_unary("ConfigInit", request, ConfigInitResponse)

    def config_show(self, show_defaults: bool = False) -> ConfigShowResponse:
        req = ConfigShowRequest(show_defaults=show_defaults)
        return self._invoke_unary("ConfigShow", req, ConfigShowResponse)

    def config_path(self) -> ConfigPathResponse:
        req = ConfigPathRequest()
        return self._invoke_unary("ConfigPath", req, ConfigPathResponse)

    def config_schema(self, path: str = "") -> ConfigSchemaResponse:
        req = ConfigSchemaRequest(path=path)
        return self._invoke_unary("ConfigSchema", req, ConfigSchemaResponse)

    def config_import_sources(self, path: str, dry_run: bool = False) -> ConfigImportSourcesResponse:
        req = ConfigImportSourcesRequest(path=path, dry_run=dry_run)
        return self._invoke_unary("ConfigImportSources", req, ConfigImportSourcesResponse)

    def begin_ingest_session(self, request: BeginIngestSessionRequest) -> BeginIngestSessionResponse:
        return self._invoke_unary("BeginIngestSession", request, BeginIngestSessionResponse)

    def persist_scan(self, request: PersistScanRequest) -> PersistScanResponse:
        return self._invoke_unary("PersistScan", request, PersistScanResponse)

    def check_document_stat(self, request: CheckDocumentStatRequest) -> CheckDocumentStatResponse:
        return self._invoke_unary("CheckDocumentStat", request, CheckDocumentStatResponse)

    def persist_document(self, request: PersistDocumentRequest) -> PersistDocumentResponse:
        return self._invoke_unary("PersistDocument", request, PersistDocumentResponse)

    def finalize_ingest_session(self, request: FinalizeIngestSessionRequest) -> FinalizeIngestSessionResponse:
        return self._invoke_unary("FinalizeIngestSession", request, FinalizeIngestSessionResponse)

    def get_embedding_batches(self, request: GetEmbeddingBatchesRequest) -> GetEmbeddingBatchesResponse:
        return self._invoke_unary("GetEmbeddingBatches", request, GetEmbeddingBatchesResponse)

    def update_embeddings(self, request: UpdateEmbeddingsRequest) -> UpdateEmbeddingsResponse:
        return self._invoke_unary("UpdateEmbeddings", request, UpdateEmbeddingsResponse)

    def execute_command(self, argv: list[str]) -> Iterator[CommandStatus]:
        req = CommandRequest(
            argv=argv,
            cwd=os.getcwd(),
            env={k: v for k, v in os.environ.items() if isinstance(v, str)},
        )
        return self._invoke_stream("ExecuteCommand", req, CommandStatus)


# Global default client
default_client = GarageClient()


def run_command_in_process(
    argv: list[str],
    executor: Optional[CommandExecutor] = None,
) -> Iterator[CommandStatus]:
    """Execute command in process, streaming CommandStatus."""
    client = GarageClient(in_process=True, servicer=GarageRpcServicer(executor=executor))
    return client.execute_command(argv)


def run_command_grpc(
    argv: list[str],
    host: str = "127.0.0.1",
    port: int = 50051,
) -> Iterator[CommandStatus]:
    """Execute command on a remote gRPC Garage server and stream CommandStatus responses."""
    client = GarageClient(host=host, port=port, in_process=False)
    return client.execute_command(argv)


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
