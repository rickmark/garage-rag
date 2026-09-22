"""Unit and integration tests for the source scanner phase."""

from __future__ import annotations

import json
import sqlite3
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

from typer.testing import CliRunner

from garage_rag.cli import app
from garage_rag.db.models import CorpusClass, Source, TrustTier
from garage_rag.ingest.pipeline import ingest_source
from garage_rag.ingest.scanner import (
    scan_feed,
    scan_filesystem,
    scan_git,
    scan_maildir,
    scan_source,
    scan_sqlite,
)

runner = CliRunner()


# ---------------------------------------------------------------------------
# 1. Filesystem Scanner Tests
# ---------------------------------------------------------------------------


def test_scan_filesystem_nonexistent_path(tmp_path: Path) -> None:
    non_existent = tmp_path / "does_not_exist"
    res = scan_filesystem(non_existent, source_slug="test-missing")
    assert res.source_slug == "test-missing"
    assert res.kind == "filesystem"
    assert res.item_count == 0
    assert res.item_type == "files"
    assert res.error is not None
    assert "does not exist" in res.error


def test_scan_filesystem_single_file(tmp_path: Path) -> None:
    txt_file = tmp_path / "doc.txt"
    txt_file.write_text("Hello world", encoding="utf-8")

    res = scan_filesystem(txt_file, source_slug="single-doc")
    assert res.item_count == 1
    assert res.item_type == "files"
    assert res.error is None

    py_file = tmp_path / "script.py"
    py_file.write_text("print('hello')", encoding="utf-8")

    res_no_code = scan_filesystem(py_file, include_code=False)
    assert res_no_code.item_count == 0

    res_with_code = scan_filesystem(py_file, include_code=True)
    assert res_with_code.item_count == 1


def test_scan_filesystem_directory(tmp_path: Path) -> None:
    (tmp_path / "notes").mkdir()
    (tmp_path / "notes" / "note1.md").write_text("# Note 1", encoding="utf-8")
    (tmp_path / "notes" / "note2.txt").write_text("Note 2", encoding="utf-8")
    (tmp_path / "notes" / ".hidden.txt").write_text("hidden", encoding="utf-8")
    (tmp_path / "notes" / "code.py").write_text("x = 1", encoding="utf-8")
    (tmp_path / "notes" / "unsupported.xyz").write_text("???", encoding="utf-8")

    res_no_code = scan_filesystem(tmp_path, source_slug="fs-test", include_code=False)
    assert res_no_code.item_count == 2
    assert res_no_code.item_type == "files"
    assert res_no_code.details["files"] == 2
    assert res_no_code.error is None

    res_with_code = scan_filesystem(tmp_path, source_slug="fs-test", include_code=True)
    assert res_with_code.item_count == 3


def test_scan_filesystem_exclude_prefixes_prune_subtrees(tmp_path: Path) -> None:
    """Prefixes are root-relative directory names, so they must be compared against
    the root-relative path, never the absolute one (which never starts with "Library/")."""
    (tmp_path / "Library").mkdir()
    (tmp_path / "Library" / "a.txt").write_text("a", encoding="utf-8")
    (tmp_path / "Library" / "deeper").mkdir()
    (tmp_path / "Library" / "deeper" / "c.txt").write_text("c", encoding="utf-8")
    (tmp_path / "Notes").mkdir()
    (tmp_path / "Notes" / "b.txt").write_text("b", encoding="utf-8")

    res = scan_filesystem(tmp_path, source_slug="prefixed", exclude_prefixes=("Library/",))
    assert res.item_count == 1
    assert res.error is None

    # Without prefixes every file counts, so the exclusion is what made the difference.
    assert scan_filesystem(tmp_path, source_slug="prefixed").item_count == 3


# ---------------------------------------------------------------------------
# 2. Git Scanner Tests
# ---------------------------------------------------------------------------


def test_scan_git_repository(tmp_path: Path) -> None:
    # Initialize a git repository
    subprocess.run(["git", "init", str(tmp_path)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Test User"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(tmp_path), "config", "user.email", "test@example.com"], check=True, capture_output=True
    )

    (tmp_path / "README.md").write_text("# Readme", encoding="utf-8")
    (tmp_path / "main.py").write_text("print('main')", encoding="utf-8")
    (tmp_path / "untracked.md").write_text("# Untracked", encoding="utf-8")

    subprocess.run(["git", "-C", str(tmp_path), "add", "README.md", "main.py"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-m", "initial commit"], check=True, capture_output=True)

    # Ingest walks the working tree, untracked files included, and the scan
    # counts the same thing, so expected_elements matches what a run sees.
    res_no_code = scan_git(tmp_path, source_slug="git-test", include_code=False)
    assert res_no_code.kind == "git"
    assert res_no_code.item_count == 2  # README.md and untracked.md (main.py is code)
    assert res_no_code.item_type == "files"
    assert res_no_code.details.get("is_git_repo") is True
    assert res_no_code.details.get("tracked_files") == 2

    res_code = scan_git(tmp_path, source_slug="git-test", include_code=True)
    assert res_code.item_count == 3  # plus main.py

    # Prefixes are root-relative, as in the walker.
    (tmp_path / "Library").mkdir()
    (tmp_path / "Library" / "x.md").write_text("# x", encoding="utf-8")
    assert scan_git(tmp_path, source_slug="git-test").item_count == 3
    assert scan_git(tmp_path, source_slug="git-test", exclude_prefixes=("Library/",)).item_count == 2


def test_scan_git_counts_what_ingest_walks(tmp_path: Path) -> None:
    """The scan's count for a git source equals the walk ingest does over it."""
    from garage_rag.ingest.walker import walk

    subprocess.run(["git", "init", str(tmp_path)], check=True, capture_output=True)
    (tmp_path / "tracked.md").write_text("# t", encoding="utf-8")
    (tmp_path / "notes.txt").write_text("untracked notes", encoding="utf-8")
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "guide.md").write_text("# g", encoding="utf-8")
    subprocess.run(["git", "-C", str(tmp_path), "add", "tracked.md"], check=True, capture_output=True)

    walked = sum(1 for _ in walk(tmp_path))
    assert scan_git(tmp_path, source_slug="git-test").item_count == walked == 3


def test_scan_git_fallback_on_non_git_dir(tmp_path: Path) -> None:
    (tmp_path / "doc.md").write_text("# Doc", encoding="utf-8")
    res = scan_git(tmp_path, source_slug="non-git")
    assert res.item_count == 1
    assert res.item_type == "files"
    assert res.details.get("is_git_repo") is False


# ---------------------------------------------------------------------------
# 3. SQLite Scanner Tests
# ---------------------------------------------------------------------------


def test_scan_sqlite_database(tmp_path: Path) -> None:
    db_file = tmp_path / "test.db"
    conn = sqlite3.connect(db_file)
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, text TEXT);")
    cursor.execute("CREATE TABLE chats (id INTEGER PRIMARY KEY, name TEXT);")
    cursor.executemany("INSERT INTO messages (text) VALUES (?);", [("msg1",), ("msg2",), ("msg3",)])
    cursor.executemany("INSERT INTO chats (name) VALUES (?);", [("chat1",), ("chat2",)])
    conn.commit()
    conn.close()

    res = scan_sqlite(db_file, source_slug="sqlite-single")
    assert res.source_slug == "sqlite-single"
    assert res.kind == "sqlite"
    assert res.item_count == 5  # 3 messages + 2 chats
    assert res.item_type == "records"
    assert res.details["databases_count"] == 1
    assert res.details["tables"]["test.db"]["messages"] == 3
    assert res.details["tables"]["test.db"]["chats"] == 2


def test_scan_sqlite_directory(tmp_path: Path) -> None:
    db1 = tmp_path / "db1.sqlite"
    conn1 = sqlite3.connect(db1)
    conn1.execute("CREATE TABLE t1 (id INT);")
    conn1.executemany("INSERT INTO t1 VALUES (?);", [(1,), (2,)])
    conn1.commit()
    conn1.close()

    db2 = tmp_path / "db2.sqlite"
    conn2 = sqlite3.connect(db2)
    conn2.execute("CREATE TABLE t2 (id INT);")
    conn2.executemany("INSERT INTO t2 VALUES (?);", [(1,), (2,), (3,), (4,)])
    conn2.commit()
    conn2.close()

    res = scan_sqlite(tmp_path, source_slug="sqlite-dir")
    assert res.item_count == 6
    assert res.item_type == "records"
    assert res.details["databases_count"] == 2


def test_scan_sqlite_apple_messages_counts_threads_not_messages(tmp_path: Path) -> None:
    db_file = tmp_path / "chat.db"
    conn = sqlite3.connect(db_file)
    cursor = conn.cursor()
    cursor.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT);")
    cursor.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT);")
    cursor.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    cursor.executemany("INSERT INTO chat (guid) VALUES (?);", [("chat1",), ("chat2",)])
    cursor.executemany(
        "INSERT INTO message (text) VALUES (?);",
        [(f"msg{i}",) for i in range(50)],
    )
    cursor.executemany("INSERT INTO handle (id) VALUES (?);", [("+15551234",)])
    conn.commit()
    conn.close()

    res = scan_sqlite(db_file, source_slug="apple-sms")
    assert res.item_count == 2  # threads (chats), not the 50 messages + 1 handle
    assert res.item_type == "threads"


# ---------------------------------------------------------------------------
# 4. Maildir Scanner Tests
# ---------------------------------------------------------------------------


def test_scan_maildir(tmp_path: Path) -> None:
    # Standard maildir structure: cur, new, tmp
    cur_dir = tmp_path / "cur"
    new_dir = tmp_path / "new"
    cur_dir.mkdir()
    new_dir.mkdir()

    (cur_dir / "1700000000.M123P456.host:2,S").write_text("From: a@b.com\n\nBody 1")
    (cur_dir / "1700000001.M123P456.host:2,S").write_text("From: a@b.com\n\nBody 2")
    (new_dir / "1700000002.M123P456.host").write_text("From: a@b.com\n\nBody 3")

    # Apple mail / .emlx file in subfolder
    sub_dir = tmp_path / "Archives"
    sub_dir.mkdir()
    (sub_dir / "12345.emlx").write_text("123\nFrom: c@d.com\n\nBody 4")
    (sub_dir / "67890.eml").write_text("From: c@d.com\n\nBody 5")

    res = scan_maildir(tmp_path, source_slug="mail-test")
    assert res.source_slug == "mail-test"
    assert res.kind == "maildir"
    assert res.item_count == 5
    assert res.item_type == "messages"
    assert res.details["messages"] == 5


# ---------------------------------------------------------------------------
# 5. Feed Scanner Tests
# ---------------------------------------------------------------------------


def test_scan_feed_rss_atom_json(tmp_path: Path) -> None:
    # RSS 2.0 Feed
    rss_content = """<?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Sample RSS</title>
        <item><title>Item 1</title></item>
        <item><title>Item 2</title></item>
      </channel>
    </rss>
    """
    (tmp_path / "feed.rss").write_text(rss_content, encoding="utf-8")

    # Atom Feed
    atom_content = """<?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Sample Atom</title>
      <entry><title>Entry 1</title></entry>
      <entry><title>Entry 2</title></entry>
      <entry><title>Entry 3</title></entry>
    </feed>
    """
    (tmp_path / "feed.atom").write_text(atom_content, encoding="utf-8")

    # JSON Feed
    json_feed = {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "Sample JSON Feed",
        "items": [
            {"id": "1", "content_text": "First"},
            {"id": "2", "content_text": "Second"},
            {"id": "3", "content_text": "Third"},
            {"id": "4", "content_text": "Fourth"},
        ],
    }
    (tmp_path / "feed.json").write_text(json.dumps(json_feed), encoding="utf-8")

    res = scan_feed(tmp_path, source_slug="feed-test")
    assert res.source_slug == "feed-test"
    assert res.kind == "feed"
    assert res.item_count == 9  # 2 RSS + 3 Atom + 4 JSON
    assert res.item_type == "entries"
    assert res.details["feeds_count"] == 3


# ---------------------------------------------------------------------------
# 6. Source Dispatcher Tests
# ---------------------------------------------------------------------------


def test_scan_source_dispatcher(tmp_path: Path) -> None:
    (tmp_path / "doc.txt").write_text("test", encoding="utf-8")

    src_fs = Source(
        slug="fs-src",
        kind="filesystem",
        root=str(tmp_path),
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
    )
    res_fs = scan_source(src_fs)
    assert res_fs.kind == "filesystem"
    assert res_fs.item_count == 1
    assert res_fs.item_type == "files"

    src_sqlite = Source(
        slug="sql-src",
        kind="sqlite",
        root=str(tmp_path),
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
    )
    res_sqlite = scan_source(src_sqlite)
    assert res_sqlite.kind == "sqlite"
    assert res_sqlite.item_type == "records"


# ---------------------------------------------------------------------------
# 7. Pipeline Scan Phase Integration Tests
# ---------------------------------------------------------------------------


def test_ingest_source_executes_scan_phase(tmp_path: Path) -> None:
    (tmp_path / "doc1.txt").write_text("Content 1", encoding="utf-8")
    (tmp_path / "doc2.txt").write_text("Content 2", encoding="utf-8")

    mock_source = MagicMock(spec=Source)
    mock_source.id = 1
    mock_source.slug = "test-slug"
    mock_source.kind = "filesystem"
    mock_source.root = str(tmp_path)
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED
    mock_source.allow_cloud_enrichment = False

    mock_session = MagicMock()
    mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_source
    mock_session.get.return_value = mock_source
    mock_session_factory = MagicMock(return_value=mock_session)
    mock_session.__enter__.return_value = mock_session

    progress_events = []

    def on_progress(counters, budget, total_items=0, phase="ingest", scan_result=None, current_item=None):
        progress_events.append((phase, total_items, counters.seen))

    # begin_session imports ensure_self_author function-locally from the resolver module.
    with patch("garage_rag.attribute.resolver.ensure_self_author"), patch("garage_rag.ingest.pipeline.ingest_one"):
        counters, walk_stats, budget = ingest_source(
            mock_session_factory,
            "test-slug",
            progress=on_progress,
        )

    assert counters.total_items == 2
    assert counters.item_type == "files"
    assert len(progress_events) >= 2
    assert progress_events[0][0] == "scan"
    assert progress_events[0][1] == 2
    assert progress_events[-1][0] == "ingest"


# ---------------------------------------------------------------------------
# 8. CLI Scan Command Tests
# ---------------------------------------------------------------------------


def test_cli_scan_command(tmp_path: Path) -> None:
    (tmp_path / "doc.txt").write_text("Hello", encoding="utf-8")
    src = Source(
        id=1,
        slug="cli-scan-src",
        kind="filesystem",
        root=str(tmp_path),
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
    )

    with patch("garage_rag.db.engine.get_session_factory") as mock_factory:
        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = src
        mock_session.query.return_value.order_by.return_value.all.return_value = [src]
        mock_session.__enter__.return_value = mock_session
        mock_factory.return_value = MagicMock(return_value=mock_session)

        # Standard table output
        result = runner.invoke(app, ["scan", "--source", "cli-scan-src"])
        assert result.exit_code == 0
        assert "cli-scan-src" in result.output
        assert "filesystem" in result.output
        assert "files" in result.output

        # JSON output
        json_result = runner.invoke(app, ["scan", "--source", "cli-scan-src", "--json"])
        assert json_result.exit_code == 0
        parsed = json.loads(json_result.output)
        assert len(parsed) == 1
        assert parsed[0]["source_slug"] == "cli-scan-src"
        assert parsed[0]["item_count"] == 1
        assert parsed[0]["item_type"] == "files"
