"""Tests for dedicated RPC functions on GarageRpcServicer and GarageClient."""

from __future__ import annotations

import json
import pytest
from pathlib import Path

from garage_rag.proto.garage_pb2 import (
    AddSourceRequest,
    ConfigPathRequest,
    ConfigSchemaRequest,
    ConfigShowRequest,
    ExtractRequest,
    ListModelsRequest,
    ListSourcesRequest,
    McpInstallRequest,
    McpStatusRequest,
    McpUninstallRequest,
    PingRequest,
    RegisterModelRequest,
    RemoveSourceRequest,
    SearchRequest,
    StatusRequest,
    VersionRequest,
)
from garage_rag.service.client import GarageClient
from garage_rag.service.server import GarageRpcServicer


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
