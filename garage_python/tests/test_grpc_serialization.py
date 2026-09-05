"""Tests for gRPC command serialization and in-process execution."""

from __future__ import annotations

import json
import pytest

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)
from garage_rag.service.client import run_command_in_process
from garage_rag.service.executor import CommandExecutor


def test_command_protobuf_serialization():
    """Verify CommandRequest and CommandStatus serialize to wire bytes and deserialize cleanly."""
    req = CommandRequest(
        argv=["search", "query test", "--limit", "5"],
        cwd="/tmp",
        env={"TEST_ENV": "1"},
        options={"mode": "hybrid"},
    )
    serialized = req.SerializeToString()
    assert isinstance(serialized, bytes)
    assert len(serialized) > 0

    deserialized = CommandRequest()
    deserialized.ParseFromString(serialized)
    assert list(deserialized.argv) == ["search", "query test", "--limit", "5"]
    assert deserialized.cwd == "/tmp"
    assert deserialized.env["TEST_ENV"] == "1"
    assert deserialized.options["mode"] == "hybrid"

    status = CommandStatus(
        type=StatusType.STATUS_COMPLETED,
        stdout="Output text",
        progress=1.0,
        exit_code=0,
        json_data='{"result": "ok"}',
    )
    status_bytes = status.SerializeToString()
    deserialized_status = CommandStatus()
    deserialized_status.ParseFromString(status_bytes)
    assert deserialized_status.type == StatusType.STATUS_COMPLETED
    assert deserialized_status.stdout == "Output text"
    assert deserialized_status.exit_code == 0
    assert json.loads(deserialized_status.json_data)["result"] == "ok"


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


def test_in_process_invalid_command():
    """Executing invalid command in-process yields error exit status."""
    statuses = list(run_command_in_process(["nonexistent_command_xyz"]))
    final_status = statuses[-1]
    assert final_status.type == StatusType.STATUS_ERROR
    assert final_status.exit_code != 0
