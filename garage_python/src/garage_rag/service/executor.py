"""In-process command executor that serializes and processes commands via gRPC protobufs."""

from __future__ import annotations

import io
import json
import sys
import threading
import traceback
from collections.abc import Iterator

from garage_rag.proto.garage_pb2 import (
    CommandRequest,
    CommandStatus,
    StatusType,
)

# Capturing output swaps the process-global ``sys.stdout``/``sys.stderr`` and the
# CLI's Rich console file. The gRPC server runs handlers on a thread pool, so two
# concurrent ExecuteCommand calls would otherwise cross-capture each other's output.
_capture_lock = threading.Lock()


class CommandExecutor:
    """Executes Garage commands, streaming CommandStatus protobuf messages."""

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

        cli_mod = importlib.import_module("garage_rag.cli")
        cli_app = cli_mod.app

        capture_out = io.StringIO()
        capture_err = io.StringIO()

        exit_code = 0
        err_message = ""
        structured_data: str | None = None

        # First check if this is a known structured command that can provide JSON data
        if argv[0] == "stats":
            structured_data = self._get_stats_json()
        elif argv[0] == "version":
            try:
                version_str = cli_mod.get_version()
            except Exception:
                version_str = "0.1.0"
            structured_data = json.dumps({"version": version_str})

        with _capture_lock:
            old_stdout = sys.stdout
            old_stderr = sys.stderr
            # Save the raw override (``_file``), not the resolved stream: rich
            # falls back to ``sys.stdout`` lazily while no file is set, and
            # restoring the resolved value would pin the console to whatever
            # ``sys.stdout`` was at capture time.
            console = getattr(cli_mod, "console", None)
            old_console_file = getattr(console, "_file", None) if console is not None else None
            if console is not None:
                console.file = capture_out
            sys.stdout = capture_out
            sys.stderr = capture_err

            try:
                # Typer CLI execution. In non-standalone mode Click/Typer *return*
                # the exit code for ``typer.Exit`` instead of raising SystemExit.
                rc = cli_app(argv, standalone_mode=False)
                exit_code = rc if isinstance(rc, int) else 0
            except SystemExit as se:
                exit_code = se.code if isinstance(se.code, int) else 0
            except Exception as e:
                exit_code = 1
                err_message = str(e)
                capture_err.write(f"\nError: {e}\n")
            finally:
                sys.stdout = old_stdout
                sys.stderr = old_stderr
                if console is not None:
                    console._file = old_console_file

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
            from garage_rag.db.models import Chunk, Document

            with session_scope() as session:
                doc_count = session.scalar(select(func.count(Document.id))) or 0
                chunk_count = session.scalar(select(func.count(Chunk.id))) or 0
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
