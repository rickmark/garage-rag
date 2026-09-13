"""In-process command executor that serializes and processes commands via gRPC protobufs."""

from __future__ import annotations

import io
import json
import sys
import traceback
from collections.abc import Iterator
from typing import Any

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)


class CommandExecutor:
    """Executes Garage commands, streaming CommandStatus protobuf messages."""

    def __init__(self, app: Any = None) -> None:
        self._app = app

    def execute_command(self, request: CommandRequest) -> Iterator[CommandStatus]:
        """Execute a command specified by CommandRequest and yield streaming CommandStatus events."""
        argv = list(request.argv)
        if not argv:
            yield CommandStatus(
                type=StatusType.STATUS_ERROR,
                exit_code=1,
                error_message="Empty command arguments received",
            )
            return

        yield CommandStatus(
            type=StatusType.STATUS_STARTED,
            progress=0.0,
            progress_message=f"Starting command: {' '.join(argv)}",
        )

        # Dispatch commands
        try:
            yield from self._dispatch_command(argv, request)
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else (0 if exc.code is None else 1)
            if code == 0:
                yield CommandStatus(
                    type=StatusType.STATUS_COMPLETED,
                    exit_code=0,
                    progress=1.0,
                    progress_message="Command completed successfully",
                )
            else:
                yield CommandStatus(
                    type=StatusType.STATUS_ERROR,
                    exit_code=code,
                    error_message=f"Command exited with code {code}",
                )
        except Exception as exc:
            err_msg = f"{type(exc).__name__}: {str(exc)}\n{traceback.format_exc()}"
            yield CommandStatus(
                type=StatusType.STATUS_ERROR,
                exit_code=1,
                error_message=str(exc),
                stderr=err_msg,
            )

    def _dispatch_command(self, argv: list[str], request: CommandRequest) -> Iterator[CommandStatus]:
        """Execute command and capture stdout/stderr as streaming chunks."""
        import importlib

        if self._app is not None:
            cli_app = self._app
            cli_mod = None
        else:
            cli_mod = importlib.import_module("garage_rag.cli")
            cli_app = cli_mod.app

        # We can run Typer app with argv
        old_stdout = sys.stdout
        old_stderr = sys.stderr
        capture_out = io.StringIO()
        capture_err = io.StringIO()

        exit_code = 0
        err_message = ""
        structured_data: str | None = None

        old_console_file = None
        if cli_mod is not None and hasattr(cli_mod, "console"):
            old_console_file = cli_mod.console.file
            cli_mod.console.file = capture_out

        try:
            # First check if this is a known structured command that can provide JSON data
            if argv[0] == "stats":
                structured_data = self._get_stats_json()
            elif argv[0] == "version":
                try:
                    version_str = cli_mod.get_version() if cli_mod else "0.1.0"
                except Exception:
                    version_str = "0.1.0"
                structured_data = json.dumps({"version": version_str})

            sys.stdout = capture_out
            sys.stderr = capture_err

            try:
                # Typer CLI execution
                cli_app(argv, standalone_mode=False)
            except SystemExit as se:
                exit_code = se.code if isinstance(se.code, int) else 0
            except Exception as e:
                exit_code = 1
                err_message = str(e)
                capture_err.write(f"\nError: {e}\n")

        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr
            if cli_mod is not None and old_console_file is not None and hasattr(cli_mod, "console"):
                cli_mod.console.file = old_console_file

        stdout_text = capture_out.getvalue()
        stderr_text = capture_err.getvalue()

        if stdout_text:
            yield CommandStatus(
                type=StatusType.STATUS_OUTPUT,
                stdout=stdout_text,
            )

        if stderr_text:
            yield CommandStatus(
                type=StatusType.STATUS_OUTPUT,
                stderr=stderr_text,
            )

        if exit_code == 0:
            yield CommandStatus(
                type=StatusType.STATUS_COMPLETED,
                exit_code=0,
                progress=1.0,
                progress_message="Command finished",
                json_data=structured_data or "",
            )
        else:
            yield CommandStatus(
                type=StatusType.STATUS_ERROR,
                exit_code=exit_code,
                error_message=err_message or f"Exited with code {exit_code}",
                json_data=structured_data or "",
            )

    def _get_stats_json(self) -> str:
        try:
            from sqlalchemy import func, select

            from garage_rag.db.engine import session_scope
            from garage_rag.db.models import Document, DocumentChunk

            with session_scope() as session:
                doc_count = session.scalar(select(func.count(Document.id))) or 0
                chunk_count = session.scalar(select(func.count(DocumentChunk.id))) or 0
                return json.dumps(
                    {
                        "documents": doc_count,
                        "chunks": chunk_count,
                        "status": "ok",
                    }
                )
        except Exception as e:
            return json.dumps({"error": str(e)})


default_executor = CommandExecutor()
