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

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.config import repo_root

log = logging.getLogger(__name__)


def sql_dir() -> Path:
    return repo_root() / "sql"


def migration_files() -> list[Path]:
    """Numbered SQL files, in lexical (therefore numeric) order."""
    directory = sql_dir()
    if not directory.is_dir():
        raise FileNotFoundError(f"SQL directory not found: {directory}")
    return sorted(directory.glob("[0-9][0-9][0-9]_*.sql"))


def apply_migrations(session: Session) -> list[str]:
    """Apply every migration file. Returns the names applied."""
    applied: list[str] = []
    for path in migration_files():
        log.info("applying %s", path.name)
        # exec_driver_sql: these files contain multiple statements and
        # dollar-quoted DO blocks, which SQLAlchemy's text() would try to parse
        # for bind parameters.
        session.connection().exec_driver_sql(path.read_text(encoding="utf-8"))
        applied.append(path.name)
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
