"""macOS XPC transport and peer code-signing authentication for Garage."""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
import platform
import threading
import time

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


def _configure_native_signatures(sec: ctypes.CDLL, cf: ctypes.CDLL) -> None:
    """Declare return/argument types for the CoreFoundation and Security calls used below.

    Without an explicit ``restype`` ctypes truncates every return value to a C ``int``,
    which silently mangles 64-bit CF object pointers.
    """
    void_p = ctypes.c_void_p
    cf.CFNumberCreate.restype = void_p
    cf.CFNumberCreate.argtypes = [void_p, ctypes.c_long, void_p]  # CFIndex theType
    cf.CFDictionaryCreate.restype = void_p
    cf.CFDictionaryCreate.argtypes = [void_p, void_p, void_p, ctypes.c_long, void_p, void_p]
    cf.CFStringCreateWithBytes.restype = void_p
    cf.CFStringCreateWithBytes.argtypes = [void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32, ctypes.c_bool]
    cf.CFRelease.restype = None
    cf.CFRelease.argtypes = [void_p]
    sec.SecCodeCopyGuestWithAttributes.restype = ctypes.c_int32  # OSStatus
    sec.SecCodeCopyGuestWithAttributes.argtypes = [void_p, void_p, ctypes.c_uint32, ctypes.POINTER(void_p)]
    sec.SecRequirementCreateWithString.restype = ctypes.c_int32
    sec.SecRequirementCreateWithString.argtypes = [void_p, ctypes.c_uint32, ctypes.POINTER(void_p)]
    sec.SecCodeCheckValidity.restype = ctypes.c_int32
    sec.SecCodeCheckValidity.argtypes = [void_p, ctypes.c_uint32, void_p]


if IS_MACOS:
    try:
        libxpc = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib")
        libsec = ctypes.CDLL(
            ctypes.util.find_library("Security") or "/System/Library/Frameworks/Security.framework/Security"
        )
        libcf = ctypes.CDLL(
            ctypes.util.find_library("CoreFoundation")
            or "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )
        _configure_native_signatures(libsec, libcf)
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
        expected_team_id: str | None = DEFAULT_TEAM_ID,
        expected_bundle_id: str | None = None,
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
        # A bogus PID is never a valid peer, on any platform.
        if pid <= 0:
            return False, "Invalid peer PID"

        if not IS_MACOS or libsec is None or libcf is None:
            if self.allow_unsigned_in_dev or not IS_MACOS:
                return True, "Allowed (non-macOS or dev mode)"
            return False, "Security framework unavailable on non-macOS platform"

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

            # The callback constants are structs; pass their addresses, not their first word.
            attr_dict = libcf.CFDictionaryCreate(
                None,
                keys,
                values,
                1,
                ctypes.byref(ctypes.c_void_p.in_dll(libcf, "kCFTypeDictionaryKeyCallBacks")),
                ctypes.byref(ctypes.c_void_p.in_dll(libcf, "kCFTypeDictionaryValueCallBacks")),
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
                    return True, f"Dev mode bypass: SecCodeCopyGuestWithAttributes returned {status}"
                return False, f"Could not obtain SecCode for PID {pid} (status {status})"

            try:
                # 2. Check code signing requirements
                req_strings: list[str] = []
                if self.expected_team_id:
                    req_strings.append(f'certificate leaf[subject.OU] = "{self.expected_team_id}"')
                if self.expected_bundle_id:
                    req_strings.append(f'identifier "{self.expected_bundle_id}"')

                if req_strings:
                    req_str = " and ".join(req_strings)
                    cf_req_str = self._to_cf_string(req_str)
                    sec_req = ctypes.c_void_p()
                    req_status = libsec.SecRequirementCreateWithString(
                        cf_req_str,
                        0,
                        ctypes.byref(sec_req),
                    )
                    libcf.CFRelease(cf_req_str)

                    if req_status != 0 or not sec_req.value:
                        if self.allow_unsigned_in_dev:
                            return True, f"Dev mode bypass: requirement string compilation failed ({req_status})"
                        return False, f"Failed to compile SecRequirement: {req_str} (status {req_status})"

                    try:
                        validity_status = libsec.SecCodeCheckValidity(
                            guest_code,
                            0,
                            sec_req,
                        )
                        if validity_status != 0:
                            if self.allow_unsigned_in_dev:
                                return True, f"Dev mode bypass: requirement check status {validity_status}"
                            return (
                                False,
                                f"Peer PID {pid} does not satisfy identity requirement (status {validity_status})",
                            )
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
    """Request handler for a macOS Mach XPC service hosting Garage command execution.

    ``handle_request_bytes`` is the complete request path (peer authentication,
    CommandRequest decoding, execution, CommandStatus encoding). A Mach listener
    that feeds it is *not* implemented in Python: ``run`` only blocks until
    stopped. The shipping app instead hosts the Python runtime inside Swift XPC
    services (``macapp/Sources/*XPCService``) that call into this package directly.
    """

    def __init__(
        self,
        service_name: str = DEFAULT_XPC_SERVICE_NAME,
        team_id: str | None = DEFAULT_TEAM_ID,
        bundle_id: str | None = None,
        allow_unsigned_in_dev: bool = False,
        executor: CommandExecutor | None = None,
    ) -> None:
        self.service_name = service_name
        self.authenticator = PeerAuthenticator(
            expected_team_id=team_id,
            expected_bundle_id=bundle_id,
            allow_unsigned_in_dev=allow_unsigned_in_dev,
        )
        self.executor = executor or default_executor
        self._stop_event = threading.Event()

    def handle_request_bytes(self, peer_pid: int, request_bytes: bytes) -> tuple[int, list[bytes]]:
        """Process serialized request bytes and return (exit_code, list of serialized response bytes)."""
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

    def run(self, stop_event: threading.Event | None = None) -> None:
        """Block until ``stop_event`` is set.

        No Mach service is registered and no XPC connections are accepted: this
        loop only keeps the process alive. See the class docstring.
        """
        self._stop_event = stop_event or threading.Event()
        logger.warning(
            "XpcServiceServer.run: no Mach listener is implemented; '%s' will not accept XPC connections "
            "(PID %d, Team ID=%r, Bundle ID=%r)",
            self.service_name,
            os.getpid(),
            self.authenticator.expected_team_id,
            self.authenticator.expected_bundle_id,
        )

        try:
            while not self._stop_event.is_set():
                time.sleep(0.5)
        finally:
            logger.info("Garage XPC service '%s' stopped.", self.service_name)

    def stop(self) -> None:
        self._stop_event.set()


def serve_xpc(
    service_name: str = DEFAULT_XPC_SERVICE_NAME,
    team_id: str | None = DEFAULT_TEAM_ID,
    bundle_id: str | None = None,
    allow_unsigned_in_dev: bool = False,
    stop_event: threading.Event | None = None,
) -> None:
    """Block until stopped. See ``XpcServiceServer``: no Mach listener is implemented."""
    server = XpcServiceServer(
        service_name=service_name,
        team_id=team_id,
        bundle_id=bundle_id,
        allow_unsigned_in_dev=allow_unsigned_in_dev,
    )
    server.run(stop_event=stop_event)
