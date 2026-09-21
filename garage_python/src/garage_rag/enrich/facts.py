"""Fact extraction: distills a document into a list of atomic facts.

Uses LangExtract (https://github.com/google/langextract) against the local
Ollama server -- the same server ``garage_rag.embed.ollama`` already talks
to -- so, like the rest of local inference in this project, document content
never leaves the machine. ``lx.extract`` defaults to a cloud Gemini model
when ``model_id``/``model_url`` are left unset, so this module always passes
both explicitly rather than relying on that default.

The prompt is deliberately generic: this module has no notion of what kind of
document it is given (notes, mail, code comments, a paper, ...), so it asks
for "facts" in the abstract rather than anything domain-specific.
"""

from __future__ import annotations

import logging
import textwrap

import langextract as lx
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.db.models import Document, Fact

log = logging.getLogger(__name__)

# A small local instruction model, pulled with `ollama pull gemma2:2b`.
DEFAULT_MODEL_ID = "gemma2:2b"

PROMPT = textwrap.dedent("""\
    Extract every standalone fact stated in this document.

    A fact is a single, self-contained claim or piece of information that
    would still be true and meaningful if read on its own, out of context.
    Use the exact wording from the document for each fact -- do not
    paraphrase, summarize, or combine multiple facts into one. Do not invent
    or infer anything that is not explicitly stated. List facts in the order
    they appear.""")

EXAMPLES = [
    lx.data.ExampleData(
        text=(
            "Acme Corp was founded in 1998 by Jane Doe. The company is "
            "headquartered in Austin, Texas, and has 42 employees."
        ),
        extractions=[
            lx.data.Extraction(
                extraction_class="fact",
                extraction_text="Acme Corp was founded in 1998 by Jane Doe.",
            ),
            lx.data.Extraction(
                extraction_class="fact",
                extraction_text="The company is headquartered in Austin, Texas.",
            ),
            lx.data.Extraction(
                extraction_class="fact",
                extraction_text="The company has 42 employees.",
            ),
        ],
    )
]


def extract_facts(
    text: str,
    *,
    model_id: str = DEFAULT_MODEL_ID,
    model_url: str | None = None,
) -> list[lx.data.Extraction]:
    """Run LangExtract over ``text``, returning only grounded extractions.

    An ungrounded extraction (``char_interval is None``) is the model quoting
    its own few-shot example rather than the input document; it is filtered
    out here rather than stored, since such a fact cannot be traced back to
    the source text.
    """
    settings = get_settings()
    result = lx.extract(
        text_or_documents=text,
        prompt_description=PROMPT,
        examples=EXAMPLES,
        model_id=model_id,
        model_url=model_url or settings.ollama_host,
        show_progress=False,
    )
    return [e for e in result.extractions if e.char_interval is not None]


def facts_from_extractions(
    document_id: int,
    extractions: list[lx.data.Extraction],
    *,
    model_id: str = DEFAULT_MODEL_ID,
) -> list[Fact]:
    """Map LangExtract extractions onto ``facts`` rows, in appearance order."""
    facts: list[Fact] = []
    for ord_, extraction in enumerate(extractions):
        interval = extraction.char_interval
        facts.append(
            Fact(
                document_id=document_id,
                ord=ord_,
                fact=extraction.extraction_text,
                fact_class=extraction.extraction_class,
                attributes=extraction.attributes or {},
                char_start=interval.start_pos if interval else None,
                char_end=interval.end_pos if interval else None,
                extractor="langextract",
                extractor_model=model_id,
            )
        )
    return facts


def extract_and_store_facts(
    session: Session,
    document: Document,
    *,
    model_id: str = DEFAULT_MODEL_ID,
    model_url: str | None = None,
) -> list[Fact]:
    """Extract facts for ``document`` and replace its ``facts`` rows.

    Re-extraction is idempotent: existing facts for the document are deleted
    before the new ones are inserted, the same replace-on-rebuild pattern
    ``ingest`` uses when a document's chunks are rebuilt.
    """
    if not document.content:
        return []

    log.info("extracting facts for document %s", document.id)
    extractions = extract_facts(document.content, model_id=model_id, model_url=model_url)

    session.query(Fact).filter(Fact.document_id == document.id).delete()
    facts = facts_from_extractions(document.id, extractions, model_id=model_id)
    session.add_all(facts)
    return facts
