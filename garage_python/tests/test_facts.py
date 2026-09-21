from __future__ import annotations

import langextract as lx

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.enrich.facts import (
    DEFAULT_MODEL_ID,
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
