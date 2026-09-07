"""Schema application.

The SQL files are written to be idempotent (``IF NOT EXISTS`` plus
``duplicate_object`` guards for enum types), so applying them repeatedly is the
migration story. That is sufficient for a single-user local corpus and avoids a
migration framework; the day a destructive change is needed, a numbered file
that performs it explicitly is added.
"""

from __future__ import annotations

import logging
from pathlib import Path

import psycopg
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

from garage_rag.config import get_settings, repo_root

log = logging.getLogger(__name__)


def sql_dir() -> Path:
    return repo_root() / "sql"


def to_psycopg_conninfo(url: str) -> str:
    """Convert an engine database URL (e.g. postgresql+psycopg://...) to psycopg conninfo/URL."""
    try:
        parsed = make_url(url)
        if "+" in parsed.drivername:
            parsed = parsed.set(drivername=parsed.drivername.split("+")[0])
        return parsed.render_as_string(hide_password=False)
    except Exception:
        if url.startswith("postgresql+"):
            prefix, rest = url.split("://", 1)
            base_driver = prefix.split("+")[0]
            return f"{base_driver}://{rest}"
        return url


def migration_files(schema_dir: Path | None = None) -> list[Path]:
    """Numbered SQL files, in lexical (therefore numeric) order."""
    directory = schema_dir if schema_dir is not None else sql_dir()
    if not directory.is_dir():
        raise FileNotFoundError(f"SQL directory not found: {directory}")
    return sorted(directory.glob("[0-9][0-9][0-9]_*.sql"))


def init_extensions(database_url: str | None = None, schema_dir: Path | None = None) -> list[str]:
    """Execute extension setup outside of SQLAlchemy on a direct raw connection."""
    raw_url = database_url or get_settings().database_url
    url = to_psycopg_conninfo(raw_url)
    applied: list[str] = []
    try:
        files = migration_files(schema_dir)
        extension_files = [f for f in files if "extension" in f.name.lower()]
    except FileNotFoundError:
        extension_files = []

    with psycopg.connect(url, autocommit=True) as conn:
        with conn.cursor() as cur:
            if extension_files:
                for path in extension_files:
                    log.info("applying extension migration outside sqlalchemy: %s", path.name)
                    cur.execute(path.read_text(encoding="utf-8"))
                    applied.append(path.name)
            else:
                log.info("creating default extensions outside sqlalchemy")
                cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
                cur.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm;")
                applied.append("default_extensions")
    return applied


def apply_migrations(
    session: Session | None = None,
    schema_dir: Path | None = None,
    database_url: str | None = None,
) -> list[str]:
    """Apply every migration file. Returns the names applied.

    Extension creation is executed outside of SQLAlchemy to prevent vector
    operations or type-registration listeners from running before the extension
    is installed.
    """
    from garage_rag.db.engine import reset_engine

    raw_url = database_url or get_settings().database_url

    # Always ensure extensions are initialized outside normal SQLAlchemy
    init_extensions(database_url=raw_url, schema_dir=schema_dir)

    files = migration_files(schema_dir)
    applied: list[str] = []

    if session is not None:
        for path in files:
            log.info("applying %s", path.name)
            # exec_driver_sql: these files contain multiple statements and
            # dollar-quoted DO blocks, which SQLAlchemy's text() would try to parse
            # for bind parameters.
            session.connection().exec_driver_sql(path.read_text(encoding="utf-8"))
            applied.append(path.name)
    else:
        conninfo = to_psycopg_conninfo(raw_url)
        with psycopg.connect(conninfo, autocommit=True) as conn:
            with conn.cursor() as cur:
                for path in files:
                    log.info("applying %s", path.name)
                    cur.execute(path.read_text(encoding="utf-8"))
                    applied.append(path.name)
        reset_engine()

    return applied


def schema_summary(session: Session) -> dict[str, int]:
    """Row counts for the core tables, for `garage stats` and smoke checks."""
    tables = [
        "sources",
        "authors",
        "author_identities",
        "documents",
        "document_authors",
        "chunks",
        "embedding_models",
        "ingest_runs",
    ]
    out: dict[str, int] = {}
    for table in tables:
        result = session.execute(text(f"SELECT count(*) FROM {table}")).scalar_one()
        out[table] = int(result)
    return out


def database_exists(url: str) -> bool:
    """Whether the target database is reachable."""
    from sqlalchemy import create_engine
    from sqlalchemy.exc import OperationalError

    try:
        engine = create_engine(url)
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        engine.dispose()
        return True
    except OperationalError:
        return False
