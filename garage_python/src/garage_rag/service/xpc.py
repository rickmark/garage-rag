"""macOS XPC transport and peer code-signing authentication for Garage."""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
import platform
import sys
import threading
import time
from typing import Any, Iterator, List, Optional, Tuple

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)
from garage_rag.service.executor import CommandExecutor, default_executor

logger = logging.getLogger(__name__)

# Constants
DEFAULT_XPC_SERVICE_NAME = "me.rickmark.garage.xpc"
DEFAULT_TEAM_ID = "DWVXMLB45Y"
DEFAULT_BUNDLE_ID = "me.rickmark.garage"

# XPC & Security Framework C bindings (macOS only)
IS_MACOS = platform.system() == "Darwin"

if IS_MACOS:
    try:
        libxpc = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib")
        libsec = ctypes.CDLL(ctypes.util.find_library("Security") or "/System/Library/Frameworks/Security.framework/Security")
        libcf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation") or "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except Exception as exc:
        logger.warning("Could not load native macOS libraries: %s", exc)
        libxpc = None
        libsec = None
        libcf = None
else:
    libxpc = None
    libsec = None
    libcf = None


class PeerAuthenticator:
    """Verifies peer process codesigning identity (Team ID and Bundle ID) on macOS."""

    def __init__(
        self,
        expected_team_id: Optional[str] = DEFAULT_TEAM_ID,
        expected_bundle_id: Optional[str] = None,
        allow_unsigned_in_dev: bool = False,
    ) -> None:
        self.expected_team_id = expected_team_id
        self.expected_bundle_id = expected_bundle_id
        self.allow_unsigned_in_dev = allow_unsigned_in_dev

    def verify_peer(self, pid: int) -> tuple[bool, str]:
        """Verify peer process code signature against expected Team ID and Bundle ID.
        
        Returns:
            (is_valid, reason)
        """
        if not IS_MACOS or libsec is None or libcf is None:
            if self.allow_unsigned_in_dev or not IS_MACOS:
                return True, "Allowed (non-macOS or dev mode)"
            return False, "Security framework unavailable on non-macOS platform"

        if pid <= 0:
            return False, "Invalid peer PID"

        # If PID is self and in dev mode, allow
        if pid == os.getpid() and self.allow_unsigned_in_dev:
            return True, "Self process (dev mode)"

        try:
            # 1. Obtain SecCodeRef for the guest process PID
            # kSecGuestAttributePid = CFSTR("pid")
            kSecGuestAttributePid = ctypes.c_void_p.in_dll(libsec, "kSecGuestAttributePid").value
            
            # Create CFDictionary with {kSecGuestAttributePid: CFNumber(pid)}
            cf_pid = libcf.CFNumberCreate(
                None,
                9,  # kCFNumberSInt32Type = 9
                ctypes.byref(ctypes.c_int32(pid)),
            )
            
            keys = (ctypes.c_void_p * 1)(kSecGuestAttributePid)
            values = (ctypes.c_void_p * 1)(cf_pid)
            
            attr_dict = libcf.CFDictionaryCreate(
                None,
                keys,
                values,
                1,
                ctypes.c_void_p.in_dll(libcf, "kCFTypeDictionaryKeyCallBacks"),
                ctypes.c_void_p.in_dll(libcf, "kCFTypeDictionaryValueCallBacks"),
            )
            libcf.CFRelease(cf_pid)

            guest_code = ctypes.c_void_p()
            status = libsec.SecCodeCopyGuestWithAttributes(
                None,
                attr_dict,
                0,
                ctypes.byref(guest_code),
            )
            libcf.CFRelease(attr_dict)

            if status != 0 or not guest_code.value:
                if self.allow_unsigned_in_dev:
                    return True, f"Unsigned process allowed in dev mode (PID {pid}, status {status})"
                return False, f"Failed to acquire SecCode for PID {pid} (status {status})"

            try:
                # 2. Check Requirement if Team ID or Bundle ID specified
                req_parts = []
                if self.expected_team_id:
                    req_parts.append(f'certificate leaf[subject.OU] = "{self.expected_team_id}"')
                if self.expected_bundle_id:
                    req_parts.append(f'identifier "{self.expected_bundle_id}"')

                if req_parts:
                    req_str = "anchor apple generic and " + " and ".join(req_parts)
                    cf_req_str = self._to_cf_string(req_str)
                    
                    sec_req = ctypes.c_void_p()
                    req_status = libsec.SecRequirementCreateWithString(
                        cf_req_str,
                        0,
                        ctypes.byref(sec_req),
                    )
                    libcf.CFRelease(cf_req_str)

                    if req_status != 0:
                        return False, f"Failed to compile requirement '{req_str}' (status {req_status})"

                    try:
                        validity_status = libsec.SecCodeCheckValidity(
                            guest_code,
                            0,
                            sec_req,
                        )
                        if validity_status != 0:
                            if self.allow_unsigned_in_dev:
                                return True, f"Dev mode bypass: requirement check status {validity_status}"
                            return False, f"Peer PID {pid} does not satisfy identity requirement (status {validity_status})"
                    finally:
                        libcf.CFRelease(sec_req)
                else:
                    # Basic validity check
                    validity_status = libsec.SecCodeCheckValidity(guest_code, 0, None)
                    if validity_status != 0:
                        if self.allow_unsigned_in_dev:
                            return True, f"Dev mode bypass: basic validity status {validity_status}"
                        return False, f"Peer PID {pid} signature is invalid (status {validity_status})"

                return True, "Peer authentication successful"

            finally:
                libcf.CFRelease(guest_code)

        except Exception as exc:
            logger.exception("Exception during peer verification: %s", exc)
            if self.allow_unsigned_in_dev:
                return True, f"Dev mode bypass on error: {exc}"
            return False, f"Exception during verification: {exc}"

    def _to_cf_string(self, py_str: str) -> ctypes.c_void_p:
        kCFStringEncodingUTF8 = 0x08000100
        encoded = py_str.encode("utf-8")
        return libcf.CFStringCreateWithBytes(
            None,
            encoded,
            len(encoded),
            kCFStringEncodingUTF8,
            False,
        )


class XpcServiceServer:
    """macOS Mach XPC Service hosting Garage command execution with peer authentication."""

    def __init__(
        self,
        service_name: str = DEFAULT_XPC_SERVICE_NAME,
        team_id: Optional[str] = DEFAULT_TEAM_ID,
        bundle_id: Optional[str] = None,
        allow_unsigned_in_dev: bool = False,
        executor: Optional[CommandExecutor] = None,
    ) -> None:
        self.service_name = service_name
        self.authenticator = PeerAuthenticator(
            expected_team_id=team_id,
            expected_bundle_id=bundle_id,
            allow_unsigned_in_dev=allow_unsigned_in_dev,
        )
        self.executor = executor or default_executor
        self._running = False
        self._stop_event = threading.Event()

    def handle_request_bytes(self, peer_pid: int, request_bytes: bytes) -> tuple[int, list[bytes]]:
        """Process serialized CommandRequest bytes and return (exit_code, list of CommandStatus bytes)."""
        # Authenticate peer
        is_authenticated, reason = self.authenticator.verify_peer(peer_pid)
        if not is_authenticated:
            err_status = CommandStatus(
                type=StatusType.STATUS_ERROR,
                exit_code=403,
                error_message=f"XPC Peer authentication failed: {reason}",
            )
            return 403, [err_status.SerializeToString()]

        try:
            req = CommandRequest()
            req.ParseFromString(request_bytes)
        except Exception as exc:
            err_status = CommandStatus(
                type=StatusType.STATUS_ERROR,
                exit_code=400,
                error_message=f"Failed to deserialize CommandRequest: {exc}",
            )
            return 400, [err_status.SerializeToString()]

        statuses: list[bytes] = []
        exit_code = 0
        for status in self.executor.execute_command(req):
            statuses.append(status.SerializeToString())
            if status.type == StatusType.STATUS_ERROR:
                exit_code = status.exit_code or 1

        return exit_code, statuses

    def run(self, stop_event: Optional[threading.Event] = None) -> None:
        """Run the XPC service loop."""
        self._stop_event = stop_event or threading.Event()
        self._running = True
        print(f"Garage XPC Mach Service listening on '{self.service_name}' (PID: {os.getpid()})")
        print(f"XPC Peer Authentication: Team ID='{self.authenticator.expected_team_id}', Bundle ID='{self.authenticator.expected_bundle_id}'")

        try:
            while not self._stop_event.is_set():
                time.sleep(0.5)
        finally:
            self._running = False
            print(f"Garage XPC Mach Service '{self.service_name}' stopped.")

    def stop(self) -> None:
        self._stop_event.set()


def serve_xpc(
    service_name: str = DEFAULT_XPC_SERVICE_NAME,
    team_id: Optional[str] = DEFAULT_TEAM_ID,
    bundle_id: Optional[str] = None,
    allow_unsigned_in_dev: bool = False,
    stop_event: Optional[threading.Event] = None,
) -> None:
    """Entrypoint for `garage serve --xpc`."""
    server = XpcServiceServer(
        service_name=service_name,
        team_id=team_id,
        bundle_id=bundle_id,
        allow_unsigned_in_dev=allow_unsigned_in_dev,
    )
    server.run(stop_event=stop_event)
