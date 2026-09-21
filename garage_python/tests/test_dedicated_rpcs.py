"""Tests for dedicated RPC functions on GarageRpcServicer and GarageClient."""

from __future__ import annotations

import json

from garage_rag.proto.garage_pb2 import (
    McpInstallRequest,
    RegisterModelRequest,
)
from garage_rag.service.client import GarageClient


def test_dedicated_rpc_ping():
    client = GarageClient(in_process=True)
    res = client.ping("hello")
    assert res.message == "hello"
    assert res.timestamp > 0


def test_dedicated_rpc_version():
    client = GarageClient(in_process=True)
    res = client.get_version()
    assert res.version == "0.1.0"


def test_dedicated_rpc_status():
    client = GarageClient(in_process=True)
    res = client.get_status()
    assert res.is_ready is True
    assert res.version == "0.1.0"


def test_dedicated_rpc_config_schema():
    client = GarageClient(in_process=True)
    res = client.config_schema()
    assert res.schema_json
    schema = json.loads(res.schema_json)
    assert "properties" in schema or "$defs" in schema or "title" in schema


def test_dedicated_rpc_mcp_status():
    client = GarageClient(in_process=True)
    res = client.mcp_status()
    assert len(res.clients) > 0
    assert res.server_command


def test_dedicated_rpc_mcp_install_dry_run():
    client = GarageClient(in_process=True)
    req = McpInstallRequest(
        target="project",
        name="test-server",
        dry_run=True,
    )
    res = client.mcp_install(req)
    assert res.success is True
    assert res.dry_run_json
    data = json.loads(res.dry_run_json)
    assert "mcpServers" in data
    assert data["mcpServers"]["test-server"]["type"] == "http"
    assert data["mcpServers"]["test-server"]["url"] == "http://127.0.0.1:8787/mcp"

    req_stdio = McpInstallRequest(
        target="project",
        name="test-server-stdio",
        dry_run=True,
        stdio=True,
    )
    res_stdio = client.mcp_install(req_stdio)
    assert res_stdio.success is True
    data_stdio = json.loads(res_stdio.dry_run_json)
    assert "command" in data_stdio["mcpServers"]["test-server-stdio"]


def test_model_info_proto_model_id():
    from garage_rag.proto.garage_pb2 import ModelInfo

    m = ModelInfo(
        slug="test-slug",
        provider="ollama",
        model_ref="test-ref",
        dims=1024,
        stored_dims=1024,
        storage_kind="vector",
        index_kind="hnsw",
        table_name="emb_test_slug",
        is_default=False,
        model_id="test-org/test-slug",
    )
    assert m.model_id == "test-org/test-slug"

    req = RegisterModelRequest(
        slug="test-slug",
        dims=1024,
        model_id="test-org/test-slug",
    )
    assert req.model_id == "test-org/test-slug"


def test_source_info_proto_document_count():
    from garage_rag.proto.garage_pb2 import SourceInfo

    s = SourceInfo(
        slug="test-source",
        kind="filesystem",
        corpus_class="document",
        trust_tier="authored",
        allow_cloud_enrichment=False,
        enabled=True,
        root="/path/to/source",
        document_count=42,
    )
    assert s.slug == "test-source"
    assert s.document_count == 42
