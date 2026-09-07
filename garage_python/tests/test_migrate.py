from pathlib import Path
from unittest.mock import MagicMock, patch

import psycopg
from garage_rag.db.engine import get_engine, reset_engine
from garage_rag.db.migrate import (
    apply_migrations,
    database_exists,
    init_extensions,
    migration_files,
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
    assert (
        to_psycopg_conninfo("host=localhost port=5432 dbname=rag")
        == "host=localhost port=5432 dbname=rag"
    )


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

    with patch("psycopg.connect", return_value=mock_conn) as mock_connect:
        with patch("garage_rag.db.engine.reset_engine") as mock_reset:
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


def test_engine_connect_listener_bypasses_pgvector_error() -> None:
    reset_engine()
    with patch("garage_rag.db.engine.register_vector", side_effect=ValueError("vector type not found")):
        engine = get_engine()
        dbapi_conn = MagicMock()
        # Find our _register_vector listener among registered connect listeners
        for fn in engine.pool.dispatch.connect:
            if getattr(fn, "__name__", "") == "_register_vector" or getattr(fn, "target", None):
                # If wrapped or direct
                try:
                    fn(dbapi_conn, None)
                except Exception as exc:
                    if "dialect" not in str(type(exc)):
                        raise
    reset_engine()
