"""In-process command executor that serializes and processes commands via gRPC protobufs."""

from __future__ import annotations

import io
import json
import os
import sys
import traceback
from contextlib import redirect_stderr, redirect_stdout
from typing import Any, Iterator, List, Optional

from rich.console import Console

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)


class CommandExecutor:
    """Executes Garage commands, streaming CommandStatus protobuf messages."""

    def __init__(self) -> None:
        pass

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

        cmd_name = argv[0]

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
        # Use Typer CLI runner / direct app invocation
        from garage_rag.cli import app
        import typer.main

        # Create string buffer for capturing console output
        output_buffer = io.StringIO()
        custom_console = Console(file=output_buffer, force_terminal=False, width=120)

        # We can run Typer app with argv
        old_stdout = sys.stdout
        old_stderr = sys.stderr
        capture_out = io.StringIO()
        capture_err = io.StringIO()

        exit_code = 0
        err_message = ""
        structured_data: Optional[str] = None

        try:
            # First check if this is a known structured command that can provide JSON data
            if argv[0] == "stats":
                structured_data = self._get_stats_json()
            elif argv[0] == "version":
                from garage_rag.cli import get_version
                structured_data = json.dumps({"version": get_version()})

            sys.stdout = capture_out
            sys.stderr = capture_err

            try:
                # Typer CLI execution
                app(argv, standalone_mode=False)
            except SystemExit as se:
                exit_code = se.code if isinstance(se.code, int) else 0
            except Exception as e:
                exit_code = 1
                err_message = str(e)
                capture_err.write(f"\nError: {e}\n")

        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr

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
            from garage_rag.db.engine import get_session
            from garage_rag.db.models import Document, DocumentChunk
            from sqlmodel import select, func

            with get_session() as session:
                doc_count = session.exec(select(func.count(Document.id))).one()
                chunk_count = session.exec(select(func.count(DocumentChunk.id))).one()
                return json.dumps({
                    "documents": doc_count,
                    "chunks": chunk_count,
                    "status": "ok",
                })
        except Exception as e:
            return json.dumps({"error": str(e)})


default_executor = CommandExecutor()
