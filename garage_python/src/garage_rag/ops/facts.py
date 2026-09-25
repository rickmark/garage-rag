"""Fact distillation over a set of documents, reported per document, and the
listing the app's Facts page browses them through."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.db.engine import session_scope
from garage_rag.db.models import Document, Source


@dataclass
class EnrichEvent:
    """One document processed: ``index`` of ``total``, with its fact count or error."""

    index: int
    total: int
    document_id: int
    uri: str
    facts: int = 0
    error: str | None = None


@dataclass
class EnrichSummary:
    model_id: str
    provider: str
    total: int
    enriched: int
    facts: int
    failed: int

    @property
    def message(self) -> str:
        text = f"{self.enriched}/{self.total} documents enriched, {self.facts:,} facts extracted"
        if self.failed:
            text += f", {self.failed} failed"
        return text


def enrich_facts(
    *,
    source: str = "*",
    document_id: int | None = None,
    model: str | None = None,
    provider: str | None = None,
    on_start: Callable[[int, str, str], None] | None = None,
    on_event: Callable[[EnrichEvent], None] | None = None,
) -> EnrichSummary:
    """Distill documents into atomic facts; re-extraction replaces a document's prior facts.

    ``document_id`` picks one document and ignores ``source``. ``model``/``provider``
    default to facts.model/facts.provider. One failing document is recorded and
    the run continues. Raises LookupError when there is nothing to enrich.
    """
    from garage_rag.enrich.facts import configured_backend, extract_and_store_facts

    model_id, provider = configured_backend(model, provider)

    with session_scope() as session:
        if document_id:
            document = session.get(Document, document_id)
            if document is None:
                raise LookupError(f"document {document_id} not found")
            documents = [document]
        else:
            query = session.query(Document)
            if source and source != "*":
                query = query.join(Source, Document.source_id == Source.id).filter(Source.slug == source)
            documents = query.order_by(Document.id).all()
        if not documents:
            raise LookupError("no documents to enrich")

        if on_start is not None:
            on_start(len(documents), model_id, provider)
        failed = 0
        total_facts = 0
        for index, document in enumerate(documents, start=1):
            event = EnrichEvent(index=index, total=len(documents), document_id=document.id, uri=document.uri or "")
            try:
                facts = extract_and_store_facts(session, document, model_id=model_id, provider=provider)
                session.commit()
                event.facts = len(facts)
                total_facts += len(facts)
            except Exception as exc:
                session.rollback()
                failed += 1
                event.error = str(exc)
            if on_event is not None:
                on_event(event)

        return EnrichSummary(
            model_id=model_id,
            provider=provider,
            total=len(documents),
            enriched=len(documents) - failed,
            facts=total_facts,
            failed=failed,
        )


# Characters of documents.content shown either side of a fact's grounded span.
EXCERPT_CONTEXT = 200


@dataclass
class FactRow:
    """One fact with the document it was distilled from."""

    id: int
    document_id: int
    ord: int
    fact: str
    fact_class: str
    attributes: dict
    char_start: int | None
    char_end: int | None
    extractor: str
    extractor_model: str | None
    created_at: datetime | None
    document_title: str | None
    document_uri: str
    source_slug: str
    corpus_class: str
    # The grounded span with EXCERPT_CONTEXT characters either side, and where it
    # starts in documents.content; None when the fact has no span or the
    # document keeps no content.
    excerpt: str | None = None
    excerpt_start: int = 0


@dataclass
class FactPage:
    facts: list[FactRow]
    total: int
    # Every fact class under the other filters, with its count, so a picker can
    # offer the classes the current search would find.
    classes: list[tuple[str, int]] = field(default_factory=list)


def _like_pattern(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def list_facts(
    session: Session,
    *,
    query: str = "",
    source: str = "",
    fact_class: str = "",
    corpus_class: str = "",
    document_id: int | None = None,
    limit: int = 100,
    offset: int = 0,
) -> FactPage:
    """Facts matching the filters, newest first, or best match first given ``query``.

    ``query`` matches a fact's words (Postgres full-text search, stemmed) or any
    substring of it, so a partial word still finds something. Empty filters
    match everything.
    """
    query = query.strip()
    params: dict[str, object] = {"ctx": EXCERPT_CONTEXT}
    base: list[str] = []
    if query:
        base.append("(f.tsv @@ websearch_to_tsquery('english', :q) OR f.fact ILIKE :like)")
        params["q"] = query
        params["like"] = _like_pattern(query)
    if source:
        base.append("s.slug = :source")
        params["source"] = source
    if corpus_class:
        base.append("d.corpus_class = CAST(:corpus_class AS corpus_class)")
        params["corpus_class"] = corpus_class
    if document_id:
        base.append("f.document_id = :document_id")
        params["document_id"] = document_id
    filtered = [*base]
    if fact_class:
        filtered.append("f.fact_class = :fact_class")
        params["fact_class"] = fact_class

    joins = "FROM facts f JOIN documents d ON d.id = f.document_id JOIN sources s ON s.id = d.source_id"

    def where(clauses: list[str]) -> str:
        return ("WHERE " + " AND ".join(clauses)) if clauses else ""

    order = (
        "ts_rank(f.tsv, websearch_to_tsquery('english', :q)) DESC, f.id DESC"
        if query
        else "f.created_at DESC, f.document_id DESC, f.ord ASC"
    )
    params["limit"] = max(limit, 1)
    params["offset"] = max(offset, 0)

    rows = session.execute(
        text(
            f"""
            SELECT f.id, f.document_id, f.ord, f.fact, f.fact_class, f.attributes,
                   f.char_start, f.char_end, f.extractor, f.extractor_model, f.created_at,
                   d.title AS document_title, d.uri AS document_uri, s.slug AS source_slug,
                   d.corpus_class::text AS corpus_class,
                   CASE WHEN f.char_start IS NOT NULL AND f.char_end IS NOT NULL AND d.content IS NOT NULL
                        THEN substr(d.content, GREATEST(f.char_start - :ctx, 0) + 1,
                                    f.char_end - GREATEST(f.char_start - :ctx, 0) + :ctx)
                   END AS excerpt,
                   GREATEST(COALESCE(f.char_start, 0) - :ctx, 0) AS excerpt_start
            {joins}
            {where(filtered)}
            ORDER BY {order}
            LIMIT :limit OFFSET :offset
            """
        ),
        params,
    ).mappings()
    facts = [
        FactRow(**{**row, "attributes": row["attributes"] or {}, "extractor": row["extractor"] or ""}) for row in rows
    ]

    total = session.execute(text(f"SELECT count(*) {joins} {where(filtered)}"), params).scalar_one()
    classes = [
        (name, count)
        for name, count in session.execute(
            text(f"SELECT f.fact_class, count(*) {joins} {where(base)} GROUP BY f.fact_class ORDER BY 2 DESC, 1"),
            params,
        ).all()
    ]
    return FactPage(facts=facts, total=int(total), classes=classes)
