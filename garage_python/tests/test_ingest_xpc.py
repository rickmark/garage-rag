"""Tests for ingest_xpc async and progress functionality."""

import asyncio
from unittest.mock import MagicMock, patch
import pytest

from garage_rag.ingest import IngestProgress, ingest_xpc, run_ingest_xpc
from garage_rag.ingest.pipeline import IngestCounters, MaterializationBudget, WalkStats


def test_ingest_progress_model():
    p = IngestProgress(
        source="test-source",
        phase="ingest",
        seen=5,
        total_items=10,
        indexed=4,
        skipped=1,
        failed=0,
        progress=0.5,
        message="Halfway there",
    )
    assert p.source == "test-source"
    assert p.progress == 0.5
    d = p.to_dict()
    assert d["source"] == "test-source"
    assert d["seen"] == 5
    assert d["total_items"] == 10


def test_ingest_xpc_async_progress():
    async def _run():
        mock_counters = IngestCounters()
        mock_counters.seen = 10
        mock_counters.total_items = 10
        mock_counters.indexed = 8
        mock_counters.skipped = 2
        mock_counters.failed = 0

        mock_walk_stats = WalkStats()
        mock_budget = MaterializationBudget()

        progress_events: list[IngestProgress] = []

        async def async_progress_handler(prog: IngestProgress):
            progress_events.append(prog)

        def fake_ingest_source(factory, slug, **kwargs):
            progress_fn = kwargs.get("progress")
            if progress_fn:
                progress_fn(mock_counters, mock_budget, total_items=10, phase="scan")
                progress_fn(mock_counters, mock_budget, total_items=10, phase="ingest")
            return mock_counters, mock_walk_stats, mock_budget

        with patch("garage_rag.ingest.pipeline.ingest_source", side_effect=fake_ingest_source):
            mock_factory = MagicMock()
            await ingest_xpc(
                source="my-source",
                progress_callback=async_progress_handler,
                session_factory=mock_factory,
            )

        assert len(progress_events) >= 2
        assert progress_events[-1].phase == "complete"
        assert progress_events[-1].source == "my-source"
        assert progress_events[-1].progress == 1.0

    asyncio.run(_run())


def test_run_ingest_xpc_sync():
    mock_counters = IngestCounters()
    mock_counters.seen = 2
    mock_counters.total_items = 2
    mock_counters.indexed = 2

    mock_walk_stats = WalkStats()
    mock_budget = MaterializationBudget()

    sync_events: list[IngestProgress] = []

    def sync_progress_handler(prog: IngestProgress):
        sync_events.append(prog)

    def fake_ingest_source(factory, slug, **kwargs):
        progress_fn = kwargs.get("progress")
        if progress_fn:
            progress_fn(mock_counters, mock_budget, total_items=2, phase="ingest")
        return mock_counters, mock_walk_stats, mock_budget

    with patch("garage_rag.ingest.pipeline.ingest_source", side_effect=fake_ingest_source):
        mock_factory = MagicMock()
        run_ingest_xpc(
            source="sync-source",
            progress_callback=sync_progress_handler,
            session_factory=mock_factory,
        )

    assert len(sync_events) >= 1
    assert sync_events[-1].phase == "complete"
    assert sync_events[-1].source == "sync-source"
