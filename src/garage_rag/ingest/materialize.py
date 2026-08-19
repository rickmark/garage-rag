"""On-demand materialization of cloud placeholder files.

Reading a placeholder makes the sync client download it. That is the mechanism,
and it is also the hazard: walking a large online-only tree would pull hundreds
of gigabytes with no upper bound and no way to stop partway.

So materialization is metered. A :class:`MaterializationBudget` caps both the
number of files and the bytes any single run will pull, and the run reports what
it fetched and what it deferred. Because ingest is idempotent, stopping at the
budget is not a failure: the next run skips everything already indexed and
spends its budget on the next slice, converging on the full corpus over several
passes instead of one unbounded one.
"""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field
from pathlib import Path

from ..config import get_settings
from ..extract.placeholder import PlaceholderFile, is_placeholder

log = logging.getLogger(__name__)


@dataclass
class MaterializationBudget:
    """Per-run cap on placeholder downloads."""

    enabled: bool = False
    max_files: int = 0  # 0 = unlimited
    max_bytes: int = 0  # 0 = unlimited
    timeout_seconds: float = 120.0

    files_done: int = 0
    bytes_done: int = 0
    deferred: int = 0
    failed: int = 0
    # Sample of deferred paths, for the run report.
    deferred_samples: list[str] = field(default_factory=list)

    @classmethod
    def from_settings(cls) -> MaterializationBudget:
        settings = get_settings()
        return cls(
            enabled=settings.materialize_placeholders,
            max_files=settings.materialize_limit,
            max_bytes=settings.materialize_max_bytes,
            timeout_seconds=settings.materialize_timeout_seconds,
        )

    @property
    def exhausted(self) -> bool:
        if self.max_files and self.files_done >= self.max_files:
            return True
        return bool(self.max_bytes and self.bytes_done >= self.max_bytes)

    def note_deferred(self, path: Path) -> None:
        self.deferred += 1
        if len(self.deferred_samples) < 20:
            self.deferred_samples.append(str(path))

    def summary(self) -> str:
        gib = self.bytes_done / 1024**3
        parts = [f"materialized {self.files_done:,} files ({gib:.2f} GiB)"]
        if self.deferred:
            parts.append(f"deferred {self.deferred:,}")
        if self.failed:
            parts.append(f"failed {self.failed:,}")
        return ", ".join(parts)


def _force_read(path: Path) -> int:
    """Read a file end to end, which is what triggers the download.

    Returns the byte count. The content is discarded; the extractor re-reads the
    file immediately afterwards, by which point it is local and warm in cache.
    """
    total = 0
    with path.open("rb") as handle:
        while block := handle.read(1 << 20):
            total += len(block)
    return total


def materialize(path: Path, budget: MaterializationBudget) -> bool:
    """Attempt to download one placeholder.

    Returns True when the file is now local. Respects the budget and never
    raises; the caller treats False as "still a placeholder".
    """
    if not budget.enabled:
        budget.note_deferred(path)
        return False

    if budget.exhausted:
        budget.note_deferred(path)
        return False

    # A blocking read on a stalled provider cannot be cancelled, so it is run on
    # a worker thread with a timeout. A timed-out thread may keep running (and
    # may even finish the download, benefiting a later run), but it stops
    # blocking this one.
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(_force_read, path)
        try:
            size = future.result(timeout=budget.timeout_seconds)
        except FutureTimeout:
            log.warning("materialization timed out after %.0fs: %s", budget.timeout_seconds, path)
            budget.failed += 1
            return False
        except OSError as exc:
            log.warning("materialization failed for %s: %s", path, exc)
            budget.failed += 1
            return False

    budget.files_done += 1
    budget.bytes_done += size

    # The provider may hand back an empty file rather than an error.
    if size == 0 or is_placeholder(path):
        log.debug("still a placeholder after read: %s", path)
        budget.failed += 1
        return False

    log.debug("materialized %s (%d bytes)", path.name, size)
    return True


def ensure_local(path: Path, budget: MaterializationBudget) -> None:
    """Materialize ``path`` if needed, or raise :class:`PlaceholderFile`.

    The single entry point the pipeline uses, so that budget accounting cannot be
    bypassed by calling the extractor directly.
    """
    if not is_placeholder(path):
        return
    if materialize(path, budget):
        return
    raise PlaceholderFile(path, "cloud")
