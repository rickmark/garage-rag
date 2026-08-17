"""Filesystem discovery.

The walk is deliberately cheap: it stats each candidate once and yields a small
record, without opening anything. Opening files is where cost lives -- parsing,
and for cloud placeholders, downloading -- so the decision about whether a file
is worth opening is made entirely from its name, size, and stat.
"""

from __future__ import annotations

import fnmatch
import logging
import os
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from ..config import (
    DEFAULT_EXCLUDE_DIRS,
    DIAGNOSTIC_DIR_PATTERNS,
    DIAGNOSTIC_FILE_PATTERNS,
    get_settings,
)
from ..db.models import CorpusClass
from ..extract.dispatch import is_indexable
from ..extract.placeholder import is_placeholder
from .classify import is_code_path

log = logging.getLogger(__name__)


@dataclass
class Candidate:
    """One file the walker considers worth looking at."""

    path: Path
    size: int
    mtime: datetime
    placeholder: bool

    @property
    def uri(self) -> str:
        return str(self.path)


@dataclass
class WalkStats:
    """What a walk saw, for the run report."""

    dirs: int = 0
    files_seen: int = 0
    yielded: int = 0
    skipped_extension: int = 0
    skipped_excluded_dir: int = 0
    skipped_code: int = 0
    skipped_too_large: int = 0
    skipped_diagnostic: int = 0
    placeholders: int = 0
    unreadable: int = 0


def _matches_any(name: str, patterns: tuple[str, ...]) -> bool:
    lowered = name.lower()
    return any(fnmatch.fnmatch(lowered, pattern.lower()) for pattern in patterns)


def is_diagnostic_dir(name: str) -> bool:
    """Whether a directory is a machine-generated diagnostic bundle."""
    return _matches_any(name, DIAGNOSTIC_DIR_PATTERNS)


def is_diagnostic_file(name: str) -> bool:
    """Whether a filename is machine output regardless of its extension."""
    return _matches_any(name, DIAGNOSTIC_FILE_PATTERNS)


def _is_hidden(name: str) -> bool:
    # Dotfiles are configuration or caches, not writing. The few exceptions
    # (dotfile repos) are not worth the noise of indexing every .DS_Store.
    return name.startswith(".")


def walk(
    root: Path,
    *,
    include_code: bool = False,
    exclude_dirs: frozenset[str] = DEFAULT_EXCLUDE_DIRS,
    exclude_prefixes: tuple[str, ...] = (),
    max_bytes: int | None = None,
    stats: WalkStats | None = None,
) -> Iterator[Candidate]:
    """Yield indexable files under ``root``.

    ``include_code`` gates source files specifically, so a source can be walked
    for documentation only -- which is the difference between ~18k documents and
    ~192k files in a tree full of checked-out repositories.
    """
    settings = get_settings()
    limit = max_bytes if max_bytes is not None else settings.max_file_bytes
    tally = stats if stats is not None else WalkStats()
    root = root.expanduser()

    def on_error(exc: OSError) -> None:
        # Permission-denied on a subtree (TCC, or another user's files) should
        # not abort the walk.
        log.debug("walk error: %s", exc)
        tally.unreadable += 1

    for dirpath, dirnames, filenames in os.walk(root, onerror=on_error, followlinks=False):
        tally.dirs += 1
        current = Path(dirpath)

        # Prune in place: os.walk honours mutation of dirnames, so excluded
        # subtrees are never descended into at all.
        kept: list[str] = []
        for name in dirnames:
            if name in exclude_dirs or _is_hidden(name):
                tally.skipped_excluded_dir += 1
                continue
            if is_diagnostic_dir(name):
                # Never descend: a sysdiagnose bundle holds thousands of files
                # and not one of them is writing.
                tally.skipped_diagnostic += 1
                continue
            kept.append(name)
        dirnames[:] = kept

        if exclude_prefixes:
            try:
                relative = current.relative_to(root).as_posix() + "/"
            except ValueError:
                relative = ""
            if relative and any(relative.startswith(p) for p in exclude_prefixes):
                dirnames[:] = []
                continue

        for name in filenames:
            tally.files_seen += 1
            if _is_hidden(name):
                continue

            if is_diagnostic_file(name):
                tally.skipped_diagnostic += 1
                continue

            path = current / name
            if not is_indexable(path):
                tally.skipped_extension += 1
                continue

            if not include_code and is_code_path(path):
                tally.skipped_code += 1
                continue

            try:
                st = path.stat()
            except OSError:
                tally.unreadable += 1
                continue

            stub = is_placeholder(path, st=st)
            if stub:
                tally.placeholders += 1
            elif st.st_size == 0:
                continue
            elif st.st_size > limit:
                tally.skipped_too_large += 1
                continue

            tally.yielded += 1
            yield Candidate(
                path=path,
                size=st.st_size,
                mtime=datetime.fromtimestamp(st.st_mtime, tz=UTC),
                placeholder=stub,
            )


def default_exclude_prefixes(source_class: CorpusClass, root: Path) -> tuple[str, ...]:
    """Source-specific subtree exclusions.

    Dropbox keeps application bundles and binary objects in known top-level
    folders; walking them yields nothing but wasted stats and, worse, wasted
    materialization budget.
    """
    from ..attribute.pathrules import EXCLUDED_PREFIXES

    if root.name == "Dropbox" or (root / ".dropbox.device").exists():
        return EXCLUDED_PREFIXES
    return ()
