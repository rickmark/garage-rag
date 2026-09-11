"""ingest"""
from collections import namedtuple
from garage_rag.db.models import Source


IngestProgress = namedtuple('IngestProgress', ['x', 'y'])


async def ingest_xpc(source: str) -> None:
    from garage_rag.db.engine import get_session_factory
    from garage_rag.ingest.pipeline import ingest_source

    factory = get_session_factory()
    if source == "*":
        with factory() as session:
            sources = [s.slug for s in session.query(Source).order_by(Source.id).all()]
    else:
        sources = [source]

    for source in sources:
        ingest_source(
            factory,
            source,
        )