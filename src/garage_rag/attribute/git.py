"""Authorship from git history.

The obvious implementation -- ``git log --follow`` per file -- is unusable here:
across ~18k tracked documents in 60 repositories it means 18k git invocations,
each walking history. Instead this runs **one** ``git log`` per repository,
streaming every commit with its touched paths, and builds a path -> authors map
in memory. Sixty subprocesses instead of eighteen thousand.

The tradeoff is ``--no-renames``: following renames requires per-file history. A
renamed file is attributed from the commits that touched its current path, which
in practice still identifies the right person.
"""

from __future__ import annotations

import logging
import subprocess
from collections import defaultdict
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

log = logging.getLogger(__name__)

# Record separators chosen to not occur in names or email addresses.
_COMMIT_MARK = "\x01"
_FIELD_SEP = "\x1f"

_GIT_TIMEOUT = 300.0


@dataclass
class AuthorTally:
    """How much one identity contributed to one file."""

    name: str
    email: str
    commits: int = 0

    @property
    def identity(self) -> tuple[str, str]:
        return (self.name, self.email.lower())


@dataclass
class RepoAttribution:
    """Everything one ``git log`` pass learned about a repository."""

    root: Path
    remote: str | None = None
    # repo-relative POSIX path -> identity key -> tally
    by_path: dict[str, dict[tuple[str, str], AuthorTally]] = field(default_factory=dict)
    commit_count: int = 0
    truncated: bool = False

    def authors_for(self, relative_path: str) -> list[AuthorTally]:
        """Contributors to one file, most commits first."""
        tallies = self.by_path.get(relative_path)
        if not tallies:
            return []
        return sorted(tallies.values(), key=lambda t: (-t.commits, t.name))

    def is_tracked(self, relative_path: str) -> bool:
        return relative_path in self.by_path


def _run_git(args: list[str], cwd: Path, *, timeout: float = _GIT_TIMEOUT) -> str | None:
    try:
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.warning("git %s failed in %s: %s", args[0], cwd, exc)
        return None
    if result.returncode != 0:
        log.debug("git %s returned %d in %s", args[0], result.returncode, cwd)
        return None
    return result.stdout


def find_repo_root(path: Path) -> Path | None:
    """Nearest enclosing git repository root, or None."""
    current = path if path.is_dir() else path.parent
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


def repo_remote(root: Path) -> str | None:
    out = _run_git(["remote", "get-url", "origin"], root, timeout=15.0)
    return out.strip() if out and out.strip() else None


def load_repo_attribution(root: Path, *, max_commits: int | None = None) -> RepoAttribution:
    """Single-pass authorship extraction for one repository."""
    attribution = RepoAttribution(root=root, remote=repo_remote(root))

    args = [
        # quotepath=false keeps non-ASCII filenames literal instead of escaped.
        "-c",
        "core.quotepath=false",
        "log",
        f"--format={_COMMIT_MARK}%aN{_FIELD_SEP}%aE",
        "--name-only",
        # Renames would need per-file history; see module docstring.
        "--no-renames",
        # Merges restate their parents' paths and would double-count.
        "--no-merges",
    ]
    if max_commits:
        args.append(f"--max-count={max_commits}")

    output = _run_git(args, root)
    if output is None:
        return attribution

    by_path: dict[str, dict[tuple[str, str], AuthorTally]] = defaultdict(dict)
    name = email = ""
    commits = 0

    for line in output.split("\n"):
        if not line:
            continue
        if line.startswith(_COMMIT_MARK):
            payload = line[1:]
            name, _, email = payload.partition(_FIELD_SEP)
            commits += 1
            continue
        if not name:
            continue

        key = (name, email.lower())
        tallies = by_path[line]
        tally = tallies.get(key)
        if tally is None:
            tallies[key] = AuthorTally(name=name, email=email, commits=1)
        else:
            tally.commits += 1

    attribution.by_path = dict(by_path)
    attribution.commit_count = commits
    attribution.truncated = bool(max_commits and commits >= max_commits)
    log.debug(
        "%s: %d commits, %d tracked paths", root.name, commits, len(attribution.by_path)
    )
    return attribution


@lru_cache(maxsize=128)
def cached_repo_attribution(root_str: str, max_commits: int | None = None) -> RepoAttribution:
    """Memoized per-repository attribution.

    A walk visits thousands of files per repository; without this the ``git log``
    would be re-run for each one. Keyed on a string because ``Path`` is not
    reliably hashable across the process boundary.
    """
    return load_repo_attribution(Path(root_str), max_commits=max_commits)


def relative_posix(root: Path, path: Path) -> str | None:
    """Path relative to ``root`` in the form git reports."""
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None


def remote_owner(remote: str | None) -> str | None:
    """Owner segment of a git remote URL, for third-party detection.

    Handles both ``git@host:owner/repo.git`` and ``https://host/owner/repo``.
    """
    if not remote:
        return None
    cleaned = remote.removesuffix(".git")
    if "@" in cleaned and ":" in cleaned.split("@", 1)[1]:
        # scp-style: git@github.com:owner/repo
        tail = cleaned.split(":", 1)[1]
    else:
        parts = cleaned.split("//", 1)
        tail = parts[1] if len(parts) == 2 else cleaned
        tail = tail.split("/", 1)[1] if "/" in tail else tail
    segments = [segment for segment in tail.split("/") if segment]
    return segments[0] if segments else None
