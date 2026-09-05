"""Tests for macOS XPC transport, peer authentication, and serialized payload handling."""

from __future__ import annotations

import os
import pytest

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)
from garage_rag.service.xpc import (
    DEFAULT_BUNDLE_ID,
    DEFAULT_TEAM_ID,
    DEFAULT_XPC_SERVICE_NAME,
    PeerAuthenticator,
    XpcServiceServer,
)


def test_peer_authenticator_dev_mode():
    """PeerAuthenticator allows self in dev mode."""
    auth = PeerAuthenticator(
        expected_team_id=DEFAULT_TEAM_ID,
        allow_unsigned_in_dev=True,
    )
    is_valid, reason = auth.verify_peer(os.getpid())
    assert is_valid is True
    assert "Allowed" in reason or "Self" in reason or "dev mode" in reason


def test_peer_authenticator_invalid_pid():
    """Negative or zero PID is rejected."""
    auth = PeerAuthenticator(
        expected_team_id=DEFAULT_TEAM_ID,
        allow_unsigned_in_dev=False,
    )
    is_valid, reason = auth.verify_peer(-1)
    assert is_valid is False
    assert "Invalid peer PID" in reason


def test_xpc_service_handle_request_bytes():
    """Test XpcServiceServer processing serialized CommandRequest bytes and returning CommandStatus bytes."""
    server = XpcServiceServer(
        service_name=DEFAULT_XPC_SERVICE_NAME,
        team_id=DEFAULT_TEAM_ID,
        allow_unsigned_in_dev=True,
    )

    req = CommandRequest(argv=["version"])
    req_bytes = req.SerializeToString()

    exit_code, status_bytes_list = server.handle_request_bytes(os.getpid(), req_bytes)
    assert exit_code == 0
    assert len(status_bytes_list) >= 2

    # Parse statuses
    statuses = []
    for sb in status_bytes_list:
        st = CommandStatus()
        st.ParseFromString(sb)
        statuses.append(st)

    types = [s.type for s in statuses]
    assert StatusType.STATUS_STARTED in types
    assert StatusType.STATUS_COMPLETED in types


def test_xpc_service_rejects_unauthorized():
    """Unauthenticated caller receives exit code 403 and error CommandStatus."""
    server = XpcServiceServer(
        service_name=DEFAULT_XPC_SERVICE_NAME,
        team_id="NONEXISTENT_TEAM_ID_9999",
        allow_unsigned_in_dev=False,
    )

    req = CommandRequest(argv=["version"])
    exit_code, status_bytes_list = server.handle_request_bytes(-1, req.SerializeToString())
    assert exit_code == 403
    assert len(status_bytes_list) == 1

    status = CommandStatus()
    status.ParseFromString(status_bytes_list[0])
    assert status.type == StatusType.STATUS_ERROR
    assert "authentication failed" in status.error_message
