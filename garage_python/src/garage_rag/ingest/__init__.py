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


@dataclass
class IngestProgress:
    source: str
    phase: str = "ingest"
    seen: int = 0
    total_items: int = 0
    indexed: int = 0
    skipped: int = 0
    failed: int = 0
    progress: float = 0.0
    message: str = ""
    error: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


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

    factory = session_factory or get_session_factory()
    if source == "*":
        with factory() as session:
            sources = [s.slug for s in session.query(Source).order_by(Source.id).all()]
    else:
        sources = [source]

    for current_source in sources:
        async def _emit_progress(prog: IngestProgress) -> None:
            _notify_c_progress(prog)
            if progress_callback is None:
                return
            if inspect.iscoroutinefunction(progress_callback):
                await progress_callback(prog)
            else:
                progress_callback(prog)

        def _handle_pipeline_progress(*args: Any, **kwargs: Any) -> None:
            counters = args[0] if len(args) > 0 else None
            phase = kwargs.get("phase", "ingest")
            total_items = kwargs.get("total_items", getattr(counters, "total_items", 0))

            seen = getattr(counters, "seen", 0)
            indexed = getattr(counters, "indexed", 0)
            skipped = getattr(counters, "skipped", 0)
            failed = getattr(counters, "failed", 0)

            if total_items and total_items > 0:
                prog_val = min(1.0, max(0.0, float(seen) / float(total_items)))
            else:
                prog_val = 0.0

            if phase == "scan":
                msg = f"Scanning {current_source}: found {total_items} items"
            elif phase == "complete":
                prog_val = 1.0
                msg = f"Ingested {current_source}: {indexed} indexed, {skipped} skipped, {failed} failed"
            else:
                msg = f"Ingesting {current_source}: {seen}/{total_items} items ({indexed} indexed)"

            prog = IngestProgress(
                source=current_source,
                phase=phase,
                seen=seen,
                total_items=total_items,
                indexed=indexed,
                skipped=skipped,
                failed=failed,
                progress=prog_val,
                message=msg,
            )

            _notify_c_progress(prog)

            if progress_callback is not None:
                if inspect.iscoroutinefunction(progress_callback):
                    try:
                        loop = asyncio.get_running_loop()
                        loop.create_task(progress_callback(prog))
                    except RuntimeError:
                        asyncio.run(progress_callback(prog))
                else:
                    progress_callback(prog)

        counters, walk_stats, budget = ingest_source(
            factory,
            current_source,
            include_code=include_code,
            limit=limit,
            force=force,
            progress=_handle_pipeline_progress,
        )

        final_prog = IngestProgress(
            source=current_source,
            phase="complete",
            seen=counters.seen,
            total_items=counters.total_items,
            indexed=counters.indexed,
            skipped=counters.skipped,
            failed=counters.failed,
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