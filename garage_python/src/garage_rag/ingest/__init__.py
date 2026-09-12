"""ingest"""
from __future__ import annotations

import asyncio
import ctypes
import inspect
import json
from dataclasses import asdict, dataclass
from typing import Any, Callable, Optional

from garage_rag.db.models import Source

_global_c_callback: Any = None
_global_cancel_requested: bool = False


@dataclass
class IngestProgress:
    source: str
    phase: str = "ingest"
    seen: int = 0
    total_items: int = 0
    indexed: int = 0
    skipped: int = 0
    failed: int = 0
    placeholders: int = 0
    chunks_written: int = 0
    item_type: str = "items"
    progress: float = 0.0
    message: str = ""
    error: Optional[str] = None
    current_item: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def cancel_ingest() -> None:
    """Request cancellation of any active ingest operation."""
    global _global_cancel_requested
    _global_cancel_requested = True


def is_ingest_cancelled() -> bool:
    """Check if cancellation has been requested."""
    return _global_cancel_requested


def reset_ingest_cancel() -> None:
    """Reset the cancellation flag."""
    global _global_cancel_requested
    _global_cancel_requested = False


def set_c_progress_callback(callback_address: int) -> None:
    """Register a C ABI function pointer (address) for real-time progress updates."""
    global _global_c_callback
    if not callback_address:
        _global_c_callback = None
    else:
        callback_type = ctypes.CFUNCTYPE(None, ctypes.c_char_p)
        _global_c_callback = callback_type(callback_address)


def _notify_c_progress(prog: IngestProgress) -> None:
    if _global_c_callback is not None:
        try:
            payload = json.dumps(prog.to_dict()).encode("utf-8")
            _global_c_callback(payload)
        except Exception:
            pass


async def ingest_xpc(
    source: str,
    progress_callback: Optional[Callable[[Any], Any]] = None,
    *,
    include_code: bool = False,
    limit: Optional[int] = None,
    force: bool = False,
    session_factory: Any = None,
) -> None:
    from garage_rag.db.engine import get_session_factory
    from garage_rag.ingest.pipeline import ingest_source

    reset_ingest_cancel()

    factory = session_factory or get_session_factory()
    if source == "*":
        with factory() as session:
            sources = [s.slug for s in session.query(Source).order_by(Source.id).all()]
    else:
        sources = [source]

    loop = asyncio.get_running_loop()

    async def _emit_progress(prog: IngestProgress) -> None:
        _notify_c_progress(prog)
        if progress_callback is None:
            return
        if inspect.iscoroutinefunction(progress_callback):
            await progress_callback(prog)
        else:
            progress_callback(prog)

    for current_source in sources:
        if is_ingest_cancelled():
            break

        start_prog = IngestProgress(
            source=current_source,
            phase="scan",
            seen=0,
            total_items=0,
            progress=0.0,
            message=f"Starting ingestion for {current_source}...",
        )
        await _emit_progress(start_prog)

        def _handle_pipeline_progress(*args: Any, **kwargs: Any) -> None:
            counters = args[0] if len(args) > 0 else None
            phase = kwargs.get("phase", "ingest")
            total_items = kwargs.get("total_items", getattr(counters, "total_items", 0))
            current_item = kwargs.get("current_item", getattr(counters, "current_item", None))

            seen = getattr(counters, "seen", 0)
            indexed = getattr(counters, "indexed", 0)
            skipped = getattr(counters, "skipped", 0)
            failed = getattr(counters, "failed", 0)
            placeholders = getattr(counters, "placeholders", 0)
            chunks_written = getattr(counters, "chunks_written", 0)
            item_type = getattr(counters, "item_type", "items")
            errors = getattr(counters, "errors", [])
            last_error = errors[-1] if errors else None

            if total_items and total_items > 0:
                prog_val = min(1.0, max(0.0, float(seen) / float(total_items)))
            else:
                prog_val = 0.0

            if phase == "scan":
                msg = f"Scanning {current_source}: found {total_items} {item_type}"
            elif phase == "complete":
                prog_val = 1.0
                msg = f"Ingested {current_source}: {indexed} indexed, {skipped} skipped, {failed} failed"
            elif phase == "cancelled":
                msg = f"Ingestion cancelled for {current_source}"
            elif current_item:
                msg = f"Ingesting {current_source} ({seen}/{total_items}): {current_item}"
            else:
                msg = f"Ingesting {current_source}: {seen}/{total_items} {item_type} ({indexed} indexed, {skipped} skipped, {failed} failed)"

            prog = IngestProgress(
                source=current_source,
                phase=phase,
                seen=seen,
                total_items=total_items,
                indexed=indexed,
                skipped=skipped,
                failed=failed,
                placeholders=placeholders,
                chunks_written=chunks_written,
                item_type=item_type,
                progress=prog_val,
                message=msg,
                error=last_error,
                current_item=current_item,
            )

            _notify_c_progress(prog)

            if progress_callback is not None:
                if inspect.iscoroutinefunction(progress_callback):
                    fut = asyncio.run_coroutine_threadsafe(progress_callback(prog), loop)
                    try:
                        fut.result(timeout=10)
                    except Exception:
                        pass
                else:
                    progress_callback(prog)

        try:
            counters, walk_stats, budget = await asyncio.to_thread(
                ingest_source,
                factory,
                current_source,
                include_code=include_code,
                limit=limit,
                force=force,
                progress=_handle_pipeline_progress,
                is_cancelled=is_ingest_cancelled,
            )
        except Exception as exc:
            err_prog = IngestProgress(
                source=current_source,
                phase="error",
                error=str(exc),
                message=f"Error ingesting {current_source}: {exc}",
                progress=0.0,
            )
            await _emit_progress(err_prog)
            raise

        if is_ingest_cancelled():
            cancel_prog = IngestProgress(
                source=current_source,
                phase="cancelled",
                seen=counters.seen,
                total_items=counters.total_items,
                indexed=counters.indexed,
                skipped=counters.skipped,
                failed=counters.failed,
                placeholders=counters.placeholders,
                chunks_written=counters.chunks_written,
                item_type=counters.item_type,
                progress=min(1.0, float(counters.seen) / float(counters.total_items)) if counters.total_items else 0.0,
                message=f"Ingestion cancelled for {current_source}",
            )
            await _emit_progress(cancel_prog)
            break

        final_prog = IngestProgress(
            source=current_source,
            phase="complete",
            seen=counters.seen,
            total_items=counters.total_items,
            indexed=counters.indexed,
            skipped=counters.skipped,
            failed=counters.failed,
            placeholders=counters.placeholders,
            chunks_written=counters.chunks_written,
            item_type=counters.item_type,
            progress=1.0,
            message=(
                f"Ingested {current_source}: seen {counters.seen}/{counters.total_items}, "
                f"indexed {counters.indexed}, skipped {counters.skipped}, failed {counters.failed}"
            ),
        )
        await _emit_progress(final_prog)


def run_ingest_xpc(
    source: str,
    progress_callback: Optional[Callable[[Any], Any]] = None,
    **kwargs: Any,
) -> None:
    """Synchronous entry point for running ingest_xpc."""
    asyncio.run(ingest_xpc(source, progress_callback=progress_callback, **kwargs))