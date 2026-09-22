"""Source scanner: counts items in sources before ingestion.

The scan phase is fast and lightweight. It determines how many items exist in
each configured source so that the subsequent ingest phase can report accurate
progress, totals, and metrics.

Different source types define "items" according to their nature:
- filesystem: count indexable candidate files within the directory tree.
- git:        count tracked/indexable files in the repository.
- sqlite:     count total rows across user tables in database file(s).
- maildir:    count message files across mail folders (cur/new/emlx/eml).
- feed:       count feed entries/items in RSS, Atom, or JSON feed files.
"""

from __future__ import annotations

import logging
import os
import re
import sqlite3
import subprocess
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from garage_rag.config import (
    DEFAULT_EXCLUDE_DIRS,
    get_settings,
)
from garage_rag.db.models import Source
from garage_rag.extract.dispatch import is_indexable
from garage_rag.ingest.classify import is_code_path
from garage_rag.ingest.walker import (
    _is_hidden,
    default_exclude_prefixes,
    is_dependency_path,
    is_diagnostic_dir,
    is_diagnostic_file,
)

log = logging.getLogger(__name__)


@dataclass
class SourceScanResult:
    """Outcome of scanning a single source."""

    source_slug: str
    kind: str
    root: Path
    item_count: int
    item_type: str  # e.g. "files", "records", "messages", "entries"
    details: dict[str, Any] = field(default_factory=dict)
    duration_seconds: float = 0.0
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "source_slug": self.source_slug,
            "kind": self.kind,
            "root": str(self.root),
            "item_count": self.item_count,
            "item_type": self.item_type,
            "details": self.details,
            "duration_seconds": round(self.duration_seconds, 4),
            "error": self.error,
        }


ScanResult = SourceScanResult


# ---------------------------------------------------------------------------
# 1. Filesystem scanner
# ---------------------------------------------------------------------------


def scan_filesystem(
    root: Path,
    *,
    source_slug: str = "",
    include_code: bool = False,
    exclude_prefixes: tuple[str, ...] = (),
) -> SourceScanResult:
    """Count indexable files in a filesystem tree.

    ``exclude_prefixes`` are root-relative directory prefixes (``"Library/"``);
    matching subtrees are pruned before descent, mirroring ``walker.walk``.
    """
    start_time = time.perf_counter()
    if not root.exists():
        return SourceScanResult(
            source_slug=source_slug,
            kind="filesystem",
            root=root,
            item_count=0,
            item_type="files",
            duration_seconds=time.perf_counter() - start_time,
            error=f"path does not exist: {root}",
        )

    if root.is_file():
        count = 0 if not is_indexable(root) or not include_code and is_code_path(root) else 1
        return SourceScanResult(
            source_slug=source_slug,
            kind="filesystem",
            root=root,
            item_count=count,
            item_type="files",
            details={"files": count, "dirs": 0},
            duration_seconds=time.perf_counter() - start_time,
        )

    limit_bytes = get_settings().max_file_bytes
    file_count = 0
    dir_count = 0
    skipped_ext = 0

    try:
        for parent_str, dirnames, filenames in os.walk(str(root), followlinks=False):
            parent = Path(parent_str)
            dir_count += 1

            # Prune excluded directories in-place
            dirnames[:] = [
                d
                for d in dirnames
                if d not in DEFAULT_EXCLUDE_DIRS
                and not _is_hidden(d)
                and not is_diagnostic_dir(d)
                and not is_dependency_path(str(parent / d))
            ]

            if exclude_prefixes and parent != root:
                relative = parent.relative_to(root).as_posix() + "/"
                if relative.startswith(exclude_prefixes):
                    dirnames[:] = []
                    continue

            for filename in filenames:
                if _is_hidden(filename) or is_diagnostic_file(filename):
                    continue
                file_path = parent / filename
                if not is_indexable(file_path):
                    skipped_ext += 1
                    continue
                if not include_code and is_code_path(file_path):
                    continue
                try:
                    st = file_path.stat()
                    if limit_bytes is not None and st.st_size > limit_bytes:
                        continue
                except OSError:
                    continue
                file_count += 1
    except OSError as exc:
        return SourceScanResult(
            source_slug=source_slug,
            kind="filesystem",
            root=root,
            item_count=file_count,
            item_type="files",
            details={"files": file_count, "dirs": dir_count},
            duration_seconds=time.perf_counter() - start_time,
            error=str(exc),
        )

    return SourceScanResult(
        source_slug=source_slug,
        kind="filesystem",
        root=root,
        item_count=file_count,
        item_type="files",
        details={"files": file_count, "dirs": dir_count, "skipped_extensions": skipped_ext},
        duration_seconds=time.perf_counter() - start_time,
    )


# ---------------------------------------------------------------------------
# 2. Git scanner
# ---------------------------------------------------------------------------


def scan_git(
    root: Path,
    *,
    source_slug: str = "",
    include_code: bool = False,
    exclude_prefixes: tuple[str, ...] = (),
) -> SourceScanResult:
    """Count tracked indexable files in a git repository."""
    start_time = time.perf_counter()
    if not root.exists():
        return SourceScanResult(
            source_slug=source_slug,
            kind="git",
            root=root,
            item_count=0,
            item_type="files",
            duration_seconds=time.perf_counter() - start_time,
            error=f"path does not exist: {root}",
        )

    # Check if git is available and root is in a git repository
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z"],
            capture_output=True,
            check=False,
            timeout=10,
        )
        if proc.returncode == 0:
            raw_entries = proc.stdout.split(b"\x00")
            tracked_count = 0
            indexable_count = 0
            for entry in raw_entries:
                if not entry:
                    continue
                tracked_count += 1
                rel_path_str = entry.decode("utf-8", errors="replace")
                if exclude_prefixes and rel_path_str.startswith(exclude_prefixes):
                    continue
                file_path = root / rel_path_str
                if is_diagnostic_file(file_path.name) or is_dependency_path(str(file_path)):
                    continue
                if not is_indexable(file_path):
                    continue
                if not include_code and is_code_path(file_path):
                    continue
                indexable_count += 1

            return SourceScanResult(
                source_slug=source_slug,
                kind="git",
                root=root,
                item_count=indexable_count,
                item_type="files",
                details={
                    "tracked_files": tracked_count,
                    "indexable_files": indexable_count,
                    "is_git_repo": True,
                },
                duration_seconds=time.perf_counter() - start_time,
            )
    except Exception as exc:
        log.debug("git ls-files failed on %s (%s); falling back to filesystem walk", root, exc)

    # Fallback to filesystem scanner
    res = scan_filesystem(
        root,
        source_slug=source_slug,
        include_code=include_code,
        exclude_prefixes=exclude_prefixes,
    )
    res.kind = "git"
    return res


# ---------------------------------------------------------------------------
# 3. SQLite scanner
# ---------------------------------------------------------------------------

# Apple Messages' chat.db always carries these three tables together; no
# other known sqlite source shares this exact signature. Detecting it lets
# the scanner count threads instead of raw message/handle/attachment rows.
_APPLE_MESSAGES_SIGNATURE_TABLES = {"chat", "message", "handle"}


def _is_apple_messages_database(tables: set[str]) -> bool:
    return _APPLE_MESSAGES_SIGNATURE_TABLES.issubset(tables)


def _count_sqlite_database_rows(db_path: Path) -> tuple[int, dict[str, int], bool]:
    """Count rows in a single SQLite database.

    Returns `(item_count, table_counts, is_thread_count)`. For an Apple
    Messages chat.db, `item_count` is the number of chat threads (one becomes
    one synthesized document each), not the sum of every table's rows, and
    `is_thread_count` is True so the caller can report "threads" rather than
    "records". Any other database counts total rows across its tables as
    before.
    """
    total_rows = 0
    table_counts: dict[str, int] = {}
    uri = f"file:{db_path.resolve()}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            tables = [row[0] for row in cursor.fetchall()]
            for table in tables:
                try:
                    # Sanitize table identifier by quoting
                    safe_name = table.replace('"', '""')
                    cursor.execute(f'SELECT count(*) FROM "{safe_name}"')
                    row = cursor.fetchone()
                    if row is not None:
                        count = int(row[0])
                        table_counts[table] = count
                        total_rows += count
                except sqlite3.Error as err:
                    log.debug("Could not count table %s in %s: %s", table, db_path, err)

            if _is_apple_messages_database(set(tables)):
                return table_counts.get("chat", 0), table_counts, True
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as exc:
        log.debug("Failed opening sqlite db at %s: %s", db_path, exc)
    return total_rows, table_counts, False


def scan_sqlite(
    root: Path,
    *,
    source_slug: str = "",
) -> SourceScanResult:
    """Count total database records across SQLite database(s)."""
    start_time = time.perf_counter()
    if not root.exists():
        return SourceScanResult(
            source_slug=source_slug,
            kind="sqlite",
            root=root,
            item_count=0,
            item_type="records",
            duration_seconds=time.perf_counter() - start_time,
            error=f"path does not exist: {root}",
        )

    db_files: list[Path] = []
    if root.is_file():
        db_files.append(root)
    else:
        for parent_str, dirnames, filenames in os.walk(str(root), followlinks=False):
            # Exclude hidden and diagnostic dirs
            dirnames[:] = [d for d in dirnames if not _is_hidden(d)]
            for filename in filenames:
                if _is_hidden(filename) or filename.endswith(("-wal", "-shm", "-journal")):
                    continue
                if filename.lower().endswith((".db", ".sqlite", ".sqlite3")):
                    db_files.append(Path(parent_str) / filename)

    total_records = 0
    all_table_counts: dict[str, dict[str, int]] = {}
    any_thread_counted = False
    for db_path in db_files:
        rows, tbls, is_thread_count = _count_sqlite_database_rows(db_path)
        total_records += rows
        all_table_counts[db_path.name] = tbls
        any_thread_counted = any_thread_counted or is_thread_count

    return SourceScanResult(
        source_slug=source_slug,
        kind="sqlite",
        root=root,
        item_count=total_records,
        item_type="threads" if any_thread_counted else "records",
        details={
            "databases_count": len(db_files),
            "databases": [p.name for p in db_files],
            "tables": all_table_counts,
        },
        duration_seconds=time.perf_counter() - start_time,
    )


# ---------------------------------------------------------------------------
# 4. Maildir scanner
# ---------------------------------------------------------------------------


def scan_maildir(
    root: Path,
    *,
    source_slug: str = "",
) -> SourceScanResult:
    """Count email message files in a Maildir or Apple Mail directory."""
    start_time = time.perf_counter()
    if not root.exists():
        return SourceScanResult(
            source_slug=source_slug,
            kind="maildir",
            root=root,
            item_count=0,
            item_type="messages",
            duration_seconds=time.perf_counter() - start_time,
            error=f"path does not exist: {root}",
        )

    message_count = 0
    folder_count = 0

    for parent_str, _dirnames, filenames in os.walk(str(root), followlinks=False):
        parent_name = os.path.basename(parent_str).lower()
        is_maildir_box = parent_name in ("cur", "new", "tmp")
        folder_count += 1

        for filename in filenames:
            if _is_hidden(filename):
                continue
            lower_name = filename.lower()
            if is_maildir_box or lower_name.endswith((".eml", ".emlx", ".msg", ".mbox")):
                message_count += 1

    return SourceScanResult(
        source_slug=source_slug,
        kind="maildir",
        root=root,
        item_count=message_count,
        item_type="messages",
        details={"messages": message_count, "folders": folder_count},
        duration_seconds=time.perf_counter() - start_time,
    )


# ---------------------------------------------------------------------------
# 5. Feed scanner
# ---------------------------------------------------------------------------


def _count_feed_items(file_path: Path) -> int:
    """Count items/entries in an XML or JSON feed file."""
    try:
        content = file_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0

    stripped = content.strip()
    # Check for JSON feed
    if stripped.startswith("{") and stripped.endswith("}"):
        try:
            import json

            data = json.loads(stripped)
            if isinstance(data, dict) and "items" in data and isinstance(data["items"], list):
                return len(data["items"])
        except Exception:
            pass

    # XML feed (RSS or Atom)
    try:
        tree = ET.fromstring(content)
        # Find item (RSS) or entry (Atom) tags
        count = 0
        for elem in tree.iter():
            tag = elem.tag.lower()
            if tag.endswith("item") or tag.endswith("entry"):
                count += 1
        if count > 0:
            return count
    except Exception:
        pass

    # Fallback regex search for RSS/Atom tags
    matches = re.findall(r"<(?:[a-zA-Z0-9_]+:)?(?:item|entry)\b", content, re.IGNORECASE)
    return len(matches)


def scan_feed(
    root: Path,
    *,
    source_slug: str = "",
) -> SourceScanResult:
    """Count feed entries across RSS/Atom/JSON feed files."""
    start_time = time.perf_counter()
    if not root.exists():
        return SourceScanResult(
            source_slug=source_slug,
            kind="feed",
            root=root,
            item_count=0,
            item_type="entries",
            duration_seconds=time.perf_counter() - start_time,
            error=f"path does not exist: {root}",
        )

    feed_files: list[Path] = []
    if root.is_file():
        feed_files.append(root)
    else:
        for parent_str, dirnames, filenames in os.walk(str(root), followlinks=False):
            dirnames[:] = [d for d in dirnames if not _is_hidden(d)]
            for filename in filenames:
                if _is_hidden(filename):
                    continue
                if filename.lower().endswith((".xml", ".rss", ".atom", ".json", ".feed")):
                    feed_files.append(Path(parent_str) / filename)

    total_entries = 0
    feed_details: dict[str, int] = {}
    for feed_path in feed_files:
        items = _count_feed_items(feed_path)
        total_entries += items
        feed_details[feed_path.name] = items

    return SourceScanResult(
        source_slug=source_slug,
        kind="feed",
        root=root,
        item_count=total_entries,
        item_type="entries",
        details={"feeds_count": len(feed_files), "feeds": feed_details},
        duration_seconds=time.perf_counter() - start_time,
    )


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------


def scan_source(
    source: Source | Any,
    *,
    include_code: bool = False,
) -> SourceScanResult:
    """Scan a source to count its items according to its kind."""
    slug = getattr(source, "slug", str(source))
    kind = getattr(source, "kind", "filesystem")
    root_val = getattr(source, "root", source)
    root = Path(root_val).expanduser() if not isinstance(root_val, Path) else root_val

    log.info("Scanning source %r (kind=%s, root=%s, include_code=%s)", slug, kind, root, include_code)

    prefixes = default_exclude_prefixes(root) if root.exists() else ()

    match kind:
        case "git":
            result = scan_git(
                root,
                source_slug=slug,
                include_code=include_code,
                exclude_prefixes=prefixes,
            )
        case "sqlite":
            result = scan_sqlite(
                root,
                source_slug=slug,
            )
        case "maildir":
            result = scan_maildir(
                root,
                source_slug=slug,
            )
        case "feed":
            result = scan_feed(
                root,
                source_slug=slug,
            )
        case _:
            result = scan_filesystem(
                root,
                source_slug=slug,
                include_code=include_code,
                exclude_prefixes=prefixes,
            )

    log.info(
        "Scan completed for source %r: found %d %s in %.2fs (error=%s)",
        slug,
        result.item_count,
        result.item_type,
        result.duration_seconds,
        result.error,
    )
    return result


def persist_scan_result(session: Any, scan_result: SourceScanResult) -> None:
    """Persist expected element counts and metadata from scan to the source row."""
    source = session.query(Source).filter_by(slug=scan_result.source_slug).one_or_none()
    if source is not None:
        source.expected_elements = scan_result.item_count
        source.expected_items = scan_result.item_count
        cfg = dict(source.config or {})
        cfg["expected_items"] = scan_result.item_count
        cfg["item_type"] = scan_result.item_type
        cfg["scan_details"] = scan_result.details
        cfg["scanned_at"] = time.time()
        source.config = cfg
