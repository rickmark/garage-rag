from pathlib import Path
from unittest.mock import MagicMock, patch

import psycopg

from garage_rag.db.migrate import (
    apply_migrations,
    database_exists,
    has_pending_migrations,
    init_extensions,
    migration_files,
    pending_migrations,
    to_psycopg_conninfo,
)


def test_to_psycopg_conninfo() -> None:
    assert (
        to_psycopg_conninfo("postgresql+psycopg://user:pass@localhost:14824/garage-rag")
        == "postgresql://user:pass@localhost:14824/garage-rag"
    )
    assert to_psycopg_conninfo("postgresql+psycopg:///rag") == "postgresql:///rag"
    assert (
        to_psycopg_conninfo("postgresql://user:pass@localhost:5432/test")
        == "postgresql://user:pass@localhost:5432/test"
    )
    assert to_psycopg_conninfo("host=localhost port=5432 dbname=rag") == "host=localhost port=5432 dbname=rag"


def test_migration_files_uses_supplied_schema_directory(tmp_path: Path) -> None:
    (tmp_path / "001_schema.sql").write_text("-- schema", encoding="utf-8")
    (tmp_path / "notes.sql").write_text("-- ignored", encoding="utf-8")

    assert migration_files(tmp_path) == [tmp_path / "001_schema.sql"]


def test_init_extensions_executes_outside_sqlalchemy(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text(
        "CREATE EXTENSION IF NOT EXISTS vector;\nCREATE EXTENSION IF NOT EXISTS pg_trgm;",
        encoding="utf-8",
    )

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    with patch("psycopg.connect", return_value=mock_conn) as mock_connect:
        applied = init_extensions(
            database_url="postgresql+psycopg://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )

        mock_connect.assert_called_once_with("postgresql://user:pass@localhost:5432/testdb", autocommit=True)
        assert mock_cursor.execute.call_count == 1
        assert "001_extensions.sql" in applied


def test_apply_migrations_without_session(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text("CREATE EXTENSION IF NOT EXISTS vector;", encoding="utf-8")
    (tmp_path / "003_core.sql").write_text("CREATE TABLE test_table (id int);", encoding="utf-8")

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    with (
        patch("psycopg.connect", return_value=mock_conn) as mock_connect,
        patch("garage_rag.db.engine.reset_engine") as mock_reset,
    ):
        applied = apply_migrations(
            schema_dir=tmp_path,
            database_url="postgresql+psycopg://user:pass@localhost:5432/testdb",
        )

        assert mock_connect.call_count == 2
        mock_connect.assert_called_with("postgresql://user:pass@localhost:5432/testdb", autocommit=True)
        assert applied == ["001_extensions.sql", "003_core.sql"]
        mock_reset.assert_called_once()


def test_apply_migrations_with_session(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text("CREATE EXTENSION IF NOT EXISTS vector;", encoding="utf-8")
    (tmp_path / "003_core.sql").write_text("CREATE TABLE test_table (id int);", encoding="utf-8")

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    mock_session = MagicMock()
    mock_driver = MagicMock()
    mock_session.connection.return_value = mock_driver

    with patch("psycopg.connect", return_value=mock_conn) as mock_connect:
        applied = apply_migrations(
            session=mock_session,
            schema_dir=tmp_path,
            database_url="postgresql+psycopg://user:pass@localhost:5432/testdb",
        )

        mock_connect.assert_called_once_with("postgresql://user:pass@localhost:5432/testdb", autocommit=True)
        assert mock_cursor.execute.call_count == 1
        mock_driver.exec_driver_sql.assert_called_once_with("CREATE TABLE test_table (id int);")
        assert applied == ["001_extensions.sql", "003_core.sql"]


def test_database_exists() -> None:
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    with patch("psycopg.connect", return_value=mock_conn):
        assert database_exists("postgresql://user:pass@localhost:5432/testdb") is True

    with patch("psycopg.connect", side_effect=psycopg.OperationalError("connection failed")):
        assert database_exists("postgresql://user:pass@localhost:5432/testdb") is False


def test_pending_migrations_and_has_pending_migrations(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text("CREATE EXTENSION IF NOT EXISTS vector;", encoding="utf-8")
    (tmp_path / "002_types.sql").write_text("CREATE TYPE corpus_class AS ENUM ('document');", encoding="utf-8")
    (tmp_path / "003_core.sql").write_text("CREATE TABLE sources (id serial);", encoding="utf-8")

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    # Scenario 1: schema_migrations does not exist
    mock_cursor.fetchone.return_value = (False,)
    with patch("psycopg.connect", return_value=mock_conn):
        assert (
            has_pending_migrations(
                database_url="postgresql://user:pass@localhost:5432/testdb",
                schema_dir=tmp_path,
            )
            is True
        )
        pending = pending_migrations(
            database_url="postgresql://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )
        assert len(pending) == 3

    # Scenario 2: schema_migrations exists, only 001 is applied
    mock_cursor.fetchone.return_value = (True,)
    mock_cursor.fetchall.return_value = [("001_extensions",)]
    with patch("psycopg.connect", return_value=mock_conn):
        assert (
            has_pending_migrations(
                database_url="postgresql://user:pass@localhost:5432/testdb",
                schema_dir=tmp_path,
            )
            is True
        )
        pending = pending_migrations(
            database_url="postgresql://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )
        assert [p.name for p in pending] == ["002_types.sql", "003_core.sql"]

    # Scenario 3: all migrations applied
    mock_cursor.fetchone.return_value = (True,)
    mock_cursor.fetchall.return_value = [("001_extensions",), ("002_types",), ("003_core",)]
    with patch("psycopg.connect", return_value=mock_conn):
        assert (
            has_pending_migrations(
                database_url="postgresql://user:pass@localhost:5432/testdb",
                schema_dir=tmp_path,
            )
            is False
        )
        pending = pending_migrations(
            database_url="postgresql://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )
        assert pending == []


def test_persist_scan_result() -> None:
    from garage_rag.db.models import Source
    from garage_rag.ingest.scanner import SourceScanResult, persist_scan_result

    mock_source = Source(slug="test-src", expected_elements=0, expected_items=0, config={})
    mock_session = MagicMock()
    mock_query = mock_session.query.return_value
    mock_filter = mock_query.filter_by.return_value
    mock_filter.one_or_none.return_value = mock_source

    scan_res = SourceScanResult(
        source_slug="test-src",
        kind="filesystem",
        root=Path("/tmp/test"),
        item_count=42,
        item_type="files",
        details={"scanned": 42},
    )

    persist_scan_result(mock_session, scan_res)

    assert mock_source.expected_elements == 42
    assert mock_source.expected_items == 42
    assert mock_source.config["expected_items"] == 42
    assert mock_source.config["item_type"] == "files"
    assert mock_source.config["scan_details"] == {"scanned": 42}
