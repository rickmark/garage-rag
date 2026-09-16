"""Tests for multi-threaded ingest and initialization/test phase isolation."""

from __future__ import annotations

import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.ingest.gateway import ExistingDocStat, IngestStorageGateway, SourceContext
from garage_rag.ingest.materialize import MaterializationBudget
from garage_rag.ingest.pipeline import IngestCounters, ingest_source
from garage_rag.ingest.scanner import SourceScanResult
from garage_rag.ingest.walker import Candidate


def _make_candidate(i: int) -> Candidate:
    return Candidate(
        path=Path(f"/fake/root/file_{i}.txt"),
        size=100 + i,
        mtime=datetime.now(tz=UTC),
        uri=f"file_{i}.txt",
        placeholder=False,
    )


def test_ingest_counters_thread_safety():
    """Verify IngestCounters behaves correctly under high concurrency."""
    counters = IngestCounters()
    num_threads = 20
    ops_per_thread = 50

    def worker():
        for _ in range(ops_per_thread):
            counters.note_seen(1)
            counters.note_indexed(chunks=2)
            counters.note_skipped()
            counters.note_placeholder()
            counters.note_rejected()
            counters.note_error("sample error")

    threads = [threading.Thread(target=worker) for _ in range(num_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    expected_ops = num_threads * ops_per_thread
    assert counters.seen == expected_ops
    assert counters.indexed == expected_ops
    assert counters.chunks_written == expected_ops * 2
    assert counters.skipped == expected_ops
    assert counters.placeholders == expected_ops
    assert counters.rejected == expected_ops
    assert counters.failed == expected_ops
    assert len(counters.errors) == 50  # Capped at 50


def test_materialization_budget_thread_safety():
    """Verify MaterializationBudget behaves correctly under high concurrency."""
    budget = MaterializationBudget(enabled=True, max_files=10000, max_bytes=1000000)
    num_threads = 20
    ops_per_thread = 50

    def worker():
        for i in range(ops_per_thread):
            budget.note_success(size=10)
            budget.note_failure()
            budget.note_deferred(Path(f"/path/{i}"))

    threads = [threading.Thread(target=worker) for _ in range(num_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    expected_ops = num_threads * ops_per_thread
    assert budget.files_done == expected_ops
    assert budget.bytes_done == expected_ops * 10
    assert budget.failed == expected_ops
    assert budget.deferred == expected_ops
    assert len(budget.deferred_samples) == 20  # Capped at 20


def test_no_worker_threads_before_initialize_and_scan_completes():
    """Verify that initialize, test/scan, and scan progress occur before any worker threads start."""
    events: list[tuple[str, int]] = []
    main_tid = threading.get_ident()

    mock_gw = MagicMock(spec=IngestStorageGateway)
    ctx = SourceContext(
        source_id=1,
        slug="test-src",
        root="/fake/root",
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
        allow_cloud_enrichment=False,
        run_id=42,
    )

    def fake_begin_session(slug, include_code=False):
        events.append(("begin_session", threading.get_ident()))
        return ctx

    def fake_persist_scan(slug, scan_res):
        events.append(("persist_scan", threading.get_ident()))

    mock_gw.begin_session.side_effect = fake_begin_session
    mock_gw.persist_scan.side_effect = fake_persist_scan
    mock_gw.finalize_session = MagicMock()

    scan_res = SourceScanResult(
        item_count=10,
        item_type="files",
        root=Path("/fake/root"),
        duration_seconds=0.01,
        is_directory=True,
    )

    def fake_scan_source(source_ctx, include_code=False):
        events.append(("scan_source", threading.get_ident()))
        return scan_res

    def fake_progress(counters, budget, **kwargs):
        phase = kwargs.get("phase")
        events.append((f"progress_{phase}", threading.get_ident()))

    candidates = [_make_candidate(i) for i in range(10)]

    def fake_ingest_one(gw, src_ctx, cand, **kwargs):
        events.append((f"ingest_one_{cand.uri}", threading.get_ident()))
        time.sleep(0.01)

    with patch("garage_rag.ingest.pipeline.scan_source", side_effect=fake_scan_source), \
         patch("garage_rag.ingest.pipeline.walk", return_value=iter(candidates)), \
         patch("garage_rag.ingest.pipeline.ingest_one", side_effect=fake_ingest_one):

        counters, walk_stats, budget = ingest_source(
            gateway=mock_gw,
            source_slug="test-src",
            progress=fake_progress,
            workers=4,
        )

    # Check the exact ordered sequence of initial events
    event_names = [e[0] for e in events]
    assert event_names[0] == "begin_session"
    assert event_names[1] == "scan_source"
    assert event_names[2] == "persist_scan"
    assert event_names[3] == "progress_scan"

    # All initial events must run on the caller thread
    assert events[0][1] == main_tid
    assert events[1][1] == main_tid
    assert events[2][1] == main_tid
    assert events[3][1] == main_tid

    # Ingest operations must only occur after progress_scan
    first_ingest_idx = next(i for i, name in enumerate(event_names) if name.startswith("ingest_one_"))
    assert first_ingest_idx > 3


def test_ingest_source_multithreaded_execution():
    """Verify that candidate files are processed concurrently across worker threads."""
    mock_gw = MagicMock(spec=IngestStorageGateway)
    ctx = SourceContext(
        source_id=1,
        slug="test-src",
        root="/fake/root",
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
        allow_cloud_enrichment=False,
        run_id=42,
    )
    mock_gw.begin_session.return_value = ctx
    mock_gw.persist_scan = MagicMock()
    mock_gw.finalize_session = MagicMock()

    scan_res = SourceScanResult(
        item_count=16,
        item_type="files",
        root=Path("/fake/root"),
        duration_seconds=0.01,
        is_directory=True,
    )

    worker_threads: set[int] = set()
    lock = threading.Lock()
    active_count = 0
    max_concurrent = 0

    def fake_ingest_one(gw, src_ctx, cand, **kwargs):
        nonlocal active_count, max_concurrent
        tid = threading.get_ident()
        with lock:
            worker_threads.add(tid)
            active_count += 1
            if active_count > max_concurrent:
                max_concurrent = active_count

        time.sleep(0.02)

        with lock:
            active_count -= 1

    candidates = [_make_candidate(i) for i in range(16)]

    with patch("garage_rag.ingest.pipeline.scan_source", return_value=scan_res), \
         patch("garage_rag.ingest.pipeline.walk", return_value=iter(candidates)), \
         patch("garage_rag.ingest.pipeline.ingest_one", side_effect=fake_ingest_one):

        counters, walk_stats, budget = ingest_source(
            gateway=mock_gw,
            source_slug="test-src",
            workers=4,
        )

    # 4 workers should have been used concurrently
    assert len(worker_threads) >= 2
    assert max_concurrent >= 2
    assert counters.seen == 16
    mock_gw.finalize_session.assert_called_once()
    assert mock_gw.finalize_session.call_args[1]["completed"] is True


def test_ingest_source_cancellation_multithreaded():
    """Verify cancellation cleanly terminates worker tasks without hanging."""
    mock_gw = MagicMock(spec=IngestStorageGateway)
    ctx = SourceContext(
        source_id=1,
        slug="test-src",
        root="/fake/root",
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
        allow_cloud_enrichment=False,
        run_id=42,
    )
    mock_gw.begin_session.return_value = ctx
    mock_gw.persist_scan = MagicMock()
    mock_gw.finalize_session = MagicMock()

    scan_res = SourceScanResult(
        item_count=50,
        item_type="files",
        root=Path("/fake/root"),
        duration_seconds=0.01,
        is_directory=True,
    )

    processed = 0
    lock = threading.Lock()
    cancel_flag = False

    def is_cancelled():
        return cancel_flag

    def fake_ingest_one(gw, src_ctx, cand, **kwargs):
        nonlocal processed, cancel_flag
        with lock:
            processed += 1
            if processed >= 3:
                cancel_flag = True
        time.sleep(0.02)

    candidates = [_make_candidate(i) for i in range(50)]

    with patch("garage_rag.ingest.pipeline.scan_source", return_value=scan_res), \
         patch("garage_rag.ingest.pipeline.walk", return_value=iter(candidates)), \
         patch("garage_rag.ingest.pipeline.ingest_one", side_effect=fake_ingest_one):

        counters, walk_stats, budget = ingest_source(
            gateway=mock_gw,
            source_slug="test-src",
            is_cancelled=is_cancelled,
            workers=4,
        )

    assert processed < 50
    assert mock_gw.finalize_session.call_args[1]["completed"] is False
