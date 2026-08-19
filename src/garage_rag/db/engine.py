"""Engine construction and pgvector type registration.

pgvector's Python bindings need per-connection type registration; without it,
vector columns come back as strings. Doing it in a ``connect`` event listener
means every pooled connection is registered exactly once, including ones the
pool creates later.
"""

from __future__ import annotations

import logging
from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from pgvector.psycopg import register_vector
from sqlalchemy import Engine, Pool, create_engine, event, text
from sqlalchemy.orm import Session, sessionmaker

from ..config import get_settings

log = logging.getLogger(__name__)

_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def get_engine() -> Engine:
    """Process-wide engine, with pgvector registered on every connection."""
    global _engine
    if _engine is not None:
        return _engine

    settings = get_settings()
    engine = create_engine(
        settings.database_url,
        pool_pre_ping=True,
        # Ingest uses a process pool; each process gets its own small pool.
        pool_size=5,
        max_overflow=5,
        future=True,
    )

    @event.listens_for(Pool, "connect")
    def _receive_connect(dbapi_connection, connection_record):
        try:
            register_vector(dbapi_connection)
        except psycopg.ProgrammingError:
            log.debug("pgvector types unavailable; assuming pre-init-db bootstrap")

    @event.listens_for(engine, "connect")
    def _register_vector(dbapi_connection, _record) -> None:  # noqa: ANN001
        # Bootstrap case: on a fresh database the `vector` extension does not
        # exist yet, and `init-db` is the command that creates it. Registration
        # must therefore be allowed to fail on that first connection. Callers
        # that create the extension reset the engine afterwards so later
        # connections do get the type registered.
        try:
            register_vector(dbapi_connection)
        except psycopg.ProgrammingError:
            log.debug("pgvector types unavailable; assuming pre-init-db bootstrap")

    _engine = engine
    return _engine


def get_session_factory() -> sessionmaker[Session]:
    global _session_factory
    if _session_factory is None:
        _session_factory = sessionmaker(bind=get_engine(), future=True, expire_on_commit=False)
    return _session_factory


@contextmanager
def session_scope() -> Iterator[Session]:
    """Transactional session: commit on success, roll back on failure.

    Ingest wraps one document per scope, so a crash leaves prior documents
    committed and the current one untouched.
    """
    factory = get_session_factory()
    session = factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def apply_search_tuning(session: Session) -> None:
    """Raise HNSW probe width for the current session, improving recall."""
    ef = int(get_settings().hnsw_ef_search)
    session.execute(text(f"SET LOCAL hnsw.ef_search = {ef}"))


def reset_engine() -> None:
    """Drop cached engine/session factory. Used by tests and by forked workers."""
    global _engine, _session_factory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _session_factory = None
