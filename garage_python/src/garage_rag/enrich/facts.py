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

Each stored fact is also, optionally, given a ``chunks`` row of its own
(``chunks.fact_id``). That is the entire embedding story: a chunk is a chunk
regardless of where its text came from, so ``embed.ollama.backfill_model``
picks up a fact's chunk the same anti-join pass it already uses for content
chunks, and every registered embedding model ends up with a vector for it --
with no fact-specific embedding path to write or maintain.
"""

from __future__ import annotations

import hashlib
import logging
import textwrap

import langextract as lx
from sqlalchemy import func
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.db.models import Chunk, Document, Fact
from garage_rag.enrich.llama_xpc_provider import LlamaXPCLanguageModel

log = logging.getLogger(__name__)

# A small local instruction model, pulled with `ollama pull gemma2:2b`.
DEFAULT_MODEL_ID = "gemma2:2b"

# Fact-distillation backends. "ollama" talks to a local Ollama server (the
# default, and the only one that runs real inference today); "llama_xpc"
# routes through LlamaXPCLanguageModel -- see that module's docstring for why
# that's an in-process call rather than an HTTP one, and for the current
# caveat that LlamaXPCService has no real model backend yet.
FACT_DISTIL_PROVIDERS = ("ollama", "llama_xpc")
DEFAULT_PROVIDER = "ollama"

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
    provider: str = DEFAULT_PROVIDER,
) -> list[lx.data.Extraction]:
    """Run LangExtract over ``text``, returning only grounded extractions.

    An ungrounded extraction (``char_interval is None``) is the model quoting
    its own few-shot example rather than the input document; it is filtered
    out here rather than stored, since such a fact cannot be traced back to
    the source text.

    ``provider`` selects the inference backend: "ollama" (default) talks to a
    local Ollama server via LangExtract's built-in provider; "llama_xpc" runs
    the prompt through ``LlamaXPCLanguageModel`` in-process instead.
    """
    if provider not in FACT_DISTIL_PROVIDERS:
        raise ValueError(f"unknown fact-distil provider {provider!r}; expected one of {FACT_DISTIL_PROVIDERS}")

    if provider == "llama_xpc":
        result = lx.extract(
            text_or_documents=text,
            prompt_description=PROMPT,
            examples=EXAMPLES,
            model=LlamaXPCLanguageModel(model_id=model_id),
            show_progress=False,
        )
    else:
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


def chunk_for_fact(fact: Fact, *, ord: int, model_id: str = DEFAULT_MODEL_ID) -> Chunk:
    """Build the ``chunks`` row that gets a fact embedded.

    A fact's chunk carries nothing but its own text -- no heading path, no
    span into ``documents.content`` (that belongs to the fact itself, via
    ``char_start``/``char_end``). ``fact.id`` must already be set, i.e. the
    fact has been flushed.
    """
    return Chunk(
        document_id=fact.document_id,
        ord=ord,
        text=fact.fact,
        chunk_sha256=hashlib.sha256(fact.fact.encode("utf-8")).digest(),
        chunker=f"facts:langextract:{model_id}",
        fact_id=fact.id,
    )


def extract_and_store_facts(
    session: Session,
    document: Document,
    *,
    model_id: str = DEFAULT_MODEL_ID,
    model_url: str | None = None,
    provider: str = DEFAULT_PROVIDER,
    queue_for_embedding: bool = True,
) -> list[Fact]:
    """Extract facts for ``document`` and replace its ``facts`` rows.

    Re-extraction is idempotent: existing facts for the document are deleted
    before the new ones are inserted, the same replace-on-rebuild pattern
    ``ingest`` uses when a document's chunks are rebuilt. Deleting a fact
    cascades (``chunks.fact_id`` is ``ON DELETE CASCADE``) into its chunk and,
    from there, into every per-model embedding table, so a re-extraction never
    leaves a stale fact vector behind.

    When ``queue_for_embedding`` is true (the default), each new fact also
    gets a ``chunks`` row appended after the document's existing chunks, ready
    for ``embed.ollama.backfill_model`` to pick up.
    """
    if not document.content:
        return []

    log.info("extracting facts for document %s via %s", document.id, provider)
    extractions = extract_facts(document.content, model_id=model_id, model_url=model_url, provider=provider)

    session.query(Fact).filter(Fact.document_id == document.id).delete()
    facts = facts_from_extractions(document.id, extractions, model_id=model_id)
    session.add_all(facts)

    if queue_for_embedding and facts:
        # Facts need ids before a chunk can reference one via fact_id.
        session.flush()
        base_ord = (
            session.query(func.coalesce(func.max(Chunk.ord), -1))
            .filter(Chunk.document_id == document.id)
            .scalar()
            + 1
        )
        session.add_all(
            chunk_for_fact(fact, ord=base_ord + i, model_id=model_id) for i, fact in enumerate(facts)
        )

    return facts
