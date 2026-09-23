"""Placeholder materialization: timeouts must not pile up blocked reader threads."""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from garage_rag.ingest import materialize as mat


@pytest.fixture(autouse=True)
def _no_stalled_reads():
    mat._stalled_reads.clear()
    yield
    mat._stalled_reads.clear()


@pytest.fixture
def stalled_read(monkeypatch):
    """Make every read block until the test releases it."""
    release = threading.Event()

    def blocked(path: Path) -> int:
        release.wait(10)
        return 0

    monkeypatch.setattr(mat, "_force_read", blocked)
    yield release
    release.set()


def _budget(**overrides) -> mat.MaterializationBudget:
    return mat.MaterializationBudget(**{"enabled": True, "timeout_seconds": 0.05, **overrides})


def test_a_timed_out_read_runs_on_a_daemon_thread(tmp_path, stalled_read):
    budget = _budget()

    assert mat.materialize(tmp_path / "stub", budget) is False

    assert budget.failed == 1
    assert len(mat._stalled_reads) == 1
    # Interpreter shutdown does not wait for daemon threads.
    assert all(thread.daemon for thread in mat._stalled_reads)


def test_stalled_reads_are_bounded(tmp_path, stalled_read):
    budget = _budget()

    for index in range(mat.MAX_STALLED_READS + 3):
        mat.materialize(tmp_path / f"stub-{index}", budget)

    assert len(mat._stalled_reads) == mat.MAX_STALLED_READS
    assert budget.failed == mat.MAX_STALLED_READS
    assert budget.deferred == 3


def test_finished_reads_free_their_slot(tmp_path, stalled_read):
    budget = _budget()
    for index in range(mat.MAX_STALLED_READS):
        mat.materialize(tmp_path / f"stub-{index}", budget)

    stalled_read.set()
    for thread in list(mat._stalled_reads):
        thread.join(5)

    assert mat._stalled_count() == 0


def test_read_errors_count_as_failures(tmp_path):
    budget = _budget(timeout_seconds=5)

    # No such file: the read raises OSError on the reader thread, and it is reported here.
    assert mat.materialize(tmp_path / "missing", budget) is False
    assert budget.failed == 1
    assert not mat._stalled_reads
