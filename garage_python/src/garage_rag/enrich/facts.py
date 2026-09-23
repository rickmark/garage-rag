"""Fact extraction: distills a document into a list of atomic facts.

Uses LangExtract (https://github.com/google/langextract) against a local model
-- the Ollama server ``garage_rag.embed.ollama`` already talks to, or the app's
LlamaXPCService -- so, like the rest of local inference in this project,
document content never leaves the machine.

Only the part of LangExtract that runs prompts through a caller-built model is
used, vendored as :mod:`garage_rag.enrich.langextract`. Upstream's
``lx.extract(model_id=...)`` chose a backend by regex on the model name, sending
``gemini*`` to Google's API and ``gpt-*``/``o1*`` to OpenAI; that routing and
those backends are not vendored, so there is no code path to a cloud model. The
backend here is always one of the two local providers
(:mod:`garage_rag.enrich.ollama_provider`,
:mod:`garage_rag.enrich.llama_xpc_provider`), and a model id that names a cloud
model is refused outright (:func:`refuse_cloud_model_id`) rather than passed to
a local server that could never serve it.

The Ollama host itself is configurable (``ollama_host``). It is assumed to be
loopback; when it is not, :func:`extract_and_store_facts` runs the document's
class through ``enrich.egress.assert_egress_allowed`` so communications are
never posted to a remote host even by configuration.

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
import re
import textwrap

from sqlalchemy import func
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.db.models import Chunk, Document, Fact
from garage_rag.enrich import langextract as lx
from garage_rag.enrich.egress import assert_egress_allowed
from garage_rag.enrich.langextract.base_model import BaseLanguageModel
from garage_rag.enrich.llama_xpc_provider import LlamaXPCLanguageModel
from garage_rag.enrich.ollama_provider import OllamaLanguageModel
from garage_rag.xpc.llama_xpc import is_loopback_url

log = logging.getLogger(__name__)

# Function-level fallbacks for direct callers of :func:`extract_facts`. The
# CLI and the ``EnrichFacts`` RPC do not use these: they take the model and
# provider from ``facts.model`` / ``facts.provider`` in the config file (see
# :func:`configured_backend`), whose defaults are the app's ``gemma2-2b``
# alias on ``llama_xpc``. ``gemma2:2b`` is the same model under its Ollama
# name, pulled with `ollama pull gemma2:2b`.
DEFAULT_MODEL_ID = "gemma2:2b"

# Fact-distillation backends. "ollama" talks to a local Ollama server;
# "llama_xpc" routes through LlamaXPCLanguageModel, which posts to the
# llama.cpp HTTP API the app's LlamaXPCService serves on loopback
# (``llama_host``) -- see that module's docstring.
FACT_DISTIL_PROVIDERS = ("ollama", "llama_xpc")
DEFAULT_PROVIDER = "ollama"


def configured_backend(model_id: str | None = None, provider: str | None = None) -> tuple[str, str]:
    """``(model_id, provider)`` for a fact-distillation run.

    Explicit arguments win; anything not given comes from ``facts.model`` and
    ``facts.provider`` in the configuration.
    """
    settings = get_settings()
    return model_id or settings.fact_model, provider or settings.fact_provider


# Model ids upstream LangExtract routed to a cloud API (its Gemini and OpenAI
# provider patterns), plus Anthropic's. ``gpt-oss`` is an open-weights model
# served by Ollama and does not match.
CLOUD_MODEL_PATTERNS = (
    r"^gemini",
    r"^gpt-3\.5",
    r"^gpt-4",
    r"^gpt4\.",
    r"^gpt-5",
    r"^gpt5\.",
    r"^o[1-9]",
    r"^claude",
)


def refuse_cloud_model_id(model_id: str) -> None:
    """Raise ``ValueError`` if ``model_id`` names a cloud-hosted model.

    Fact distillation only runs on local models, so such an id is a
    configuration mistake; failing with a clear message beats a model-not-found
    error from the local server.
    """
    if any(re.match(pattern, model_id, re.IGNORECASE) for pattern in CLOUD_MODEL_PATTERNS):
        raise ValueError(
            f"{model_id!r} names a cloud-hosted model; fact distillation runs only on local models "
            f"(facts.provider {' or '.join(FACT_DISTIL_PROVIDERS)})"
        )


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


def resolve_model_url(model_url: str | None = None) -> str:
    """The Ollama endpoint fact extraction will post to."""
    return model_url or get_settings().ollama_host


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

    ``provider`` selects the inference backend: "ollama" (default) posts to a
    local Ollama server through :class:`OllamaLanguageModel`; "llama_xpc" runs
    the prompt through :class:`LlamaXPCLanguageModel`, which posts to the app's
    LlamaXPCService on loopback. Both emit JSON. A cloud model id is refused
    (:func:`refuse_cloud_model_id`).
    """
    if provider not in FACT_DISTIL_PROVIDERS:
        raise ValueError(f"unknown fact-distil provider {provider!r}; expected one of {FACT_DISTIL_PROVIDERS}")
    refuse_cloud_model_id(model_id)

    if provider == "llama_xpc":
        model: BaseLanguageModel = LlamaXPCLanguageModel(model_id=model_id)
    else:
        model = OllamaLanguageModel(model_id=model_id, model_url=resolve_model_url(model_url))
    result = lx.extract(text_or_documents=text, prompt_description=PROMPT, examples=EXAMPLES, model=model)
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
    leaves a stale fact vector behind -- including when the document has since
    become empty, which clears its facts rather than keeping the old ones.

    When ``queue_for_embedding`` is true (the default), each new fact also
    gets a ``chunks`` row appended after the document's existing chunks, ready
    for ``embed.ollama.backfill_model`` to pick up.

    If the Ollama endpoint is not on this machine, the document's corpus class
    is checked through the egress chokepoint first: a communication is never
    posted to a remote host, whatever the configuration says.
    """
    if provider == "ollama":
        url = resolve_model_url(model_url)
        if not is_loopback_url(url):
            log.warning("ollama_host %s is not loopback; applying egress policy to document %s", url, document.id)
            assert_egress_allowed(document.corpus_class)

    session.query(Fact).filter(Fact.document_id == document.id).delete()
    if not document.content:
        return []

    log.info("extracting facts for document %s via %s", document.id, provider)
    extractions = extract_facts(document.content, model_id=model_id, model_url=model_url, provider=provider)

    facts = facts_from_extractions(document.id, extractions, model_id=model_id)
    session.add_all(facts)

    if queue_for_embedding and facts:
        # Facts need ids before a chunk can reference one via fact_id.
        session.flush()
        base_ord = (
            session.query(func.coalesce(func.max(Chunk.ord), -1)).filter(Chunk.document_id == document.id).scalar() + 1
        )
        session.add_all(chunk_for_fact(fact, ord=base_ord + i, model_id=model_id) for i, fact in enumerate(facts))

    return facts
