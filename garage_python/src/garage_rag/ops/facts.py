"""Fact distillation over a set of documents, reported per document."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

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
