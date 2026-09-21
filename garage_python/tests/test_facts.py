from __future__ import annotations

import hashlib
from unittest.mock import MagicMock

import langextract as lx

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.db.models import Chunk, Document, Fact
from garage_rag.enrich.facts import (
    DEFAULT_MODEL_ID,
    chunk_for_fact,
    extract_and_store_facts,
    extract_facts,
    facts_from_extractions,
)


def _extraction(text: str, *, start: int, end: int, attributes: dict | None = None) -> lx.data.Extraction:
    return lx.data.Extraction(
        extraction_class="fact",
        extraction_text=text,
        char_interval=lx.data.CharInterval(start_pos=start, end_pos=end),
        attributes=attributes,
    )


def test_extract_facts_stays_local_and_drops_ungrounded(monkeypatch) -> None:
    captured: dict = {}

    grounded = _extraction("Acme Corp was founded in 1998.", start=0, end=31)
    ungrounded = lx.data.Extraction(extraction_class="fact", extraction_text="not in the text")

    class Result:
        extractions = [grounded, ungrounded]

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)
    set_settings(Settings(ollama_host="http://ollama.example:11434"))
    try:
        extractions = extract_facts("Acme Corp was founded in 1998.")
    finally:
        reset_settings()

    assert extractions == [grounded]
    assert captured["model_id"] == DEFAULT_MODEL_ID
    assert captured["model_url"] == "http://ollama.example:11434"
    assert captured["prompt_description"]
    assert captured["examples"]


def test_facts_from_extractions_preserves_order_and_grounding() -> None:
    extractions = [
        _extraction("First fact.", start=0, end=11, attributes={"topic": "a"}),
        _extraction("Second fact.", start=12, end=24),
    ]

    facts = facts_from_extractions(document_id=7, extractions=extractions, model_id="gemma2:2b")

    assert [f.ord for f in facts] == [0, 1]
    assert [f.fact for f in facts] == ["First fact.", "Second fact."]
    assert facts[0].attributes == {"topic": "a"}
    assert facts[1].attributes == {}
    assert facts[0].char_start == 0 and facts[0].char_end == 11
    assert all(f.document_id == 7 for f in facts)
    assert all(f.extractor == "langextract" for f in facts)
    assert all(f.extractor_model == "gemma2:2b" for f in facts)


def test_chunk_for_fact_builds_an_embeddable_chunk_row() -> None:
    fact = Fact(id=42, document_id=7, fact="Acme Corp was founded in 1998.")

    chunk = chunk_for_fact(fact, ord=5, model_id="gemma2:2b")

    assert isinstance(chunk, Chunk)
    assert chunk.document_id == 7
    assert chunk.ord == 5
    assert chunk.text == "Acme Corp was founded in 1998."
    assert chunk.fact_id == 42
    assert chunk.chunker == "facts:langextract:gemma2:2b"
    assert chunk.chunk_sha256 == hashlib.sha256(b"Acme Corp was founded in 1998.").digest()


def test_extract_and_store_facts_queues_chunks_after_existing_ones(monkeypatch) -> None:
    document = Document(id=9, content="Acme Corp was founded in 1998. It is public.")
    extraction = _extraction("Acme Corp was founded in 1998.", start=0, end=31)

    monkeypatch.setattr(
        "garage_rag.enrich.facts.extract_facts",
        lambda text, **kwargs: [extraction],
    )

    session = MagicMock()
    # Shared by the facts-delete query and the max(ord) lookup; only the
    # latter's .scalar() return value is exercised.
    session.query.return_value.filter.return_value.scalar.return_value = 4

    added: list = []
    session.add_all.side_effect = lambda items: added.extend(items)

    def fake_flush() -> None:
        for i, obj in enumerate(o for o in added if isinstance(o, Fact)):
            obj.id = 100 + i

    session.flush.side_effect = fake_flush

    extract_and_store_facts(session, document)

    assert session.flush.called
    fact_rows = [row for row in added if isinstance(row, Fact)]
    chunk_rows = [row for row in added if isinstance(row, Chunk)]
    assert len(fact_rows) == 1
    assert len(chunk_rows) == 1
    # base_ord = max(existing ord) + 1 = 5
    assert chunk_rows[0].ord == 5
    assert chunk_rows[0].fact_id == fact_rows[0].id


def test_extract_and_store_facts_can_skip_embedding_queue(monkeypatch) -> None:
    document = Document(id=9, content="Acme Corp was founded in 1998.")
    extraction = _extraction("Acme Corp was founded in 1998.", start=0, end=31)

    monkeypatch.setattr(
        "garage_rag.enrich.facts.extract_facts",
        lambda text, **kwargs: [extraction],
    )

    session = MagicMock()
    added: list = []
    session.add_all.side_effect = lambda items: added.extend(items)

    extract_and_store_facts(session, document, queue_for_embedding=False)

    assert not session.flush.called
    assert all(isinstance(row, Fact) for row in added)
    assert len(added) == 1
