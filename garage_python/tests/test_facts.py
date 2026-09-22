from __future__ import annotations

import hashlib
from unittest.mock import MagicMock

import langextract as lx
import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.db.models import Chunk, CorpusClass, Document, Fact
from garage_rag.enrich.egress import EgressBlocked
from garage_rag.enrich.facts import (
    DEFAULT_MODEL_ID,
    OLLAMA_PROVIDER,
    chunk_for_fact,
    extract_and_store_facts,
    extract_facts,
    facts_from_extractions,
    is_loopback_url,
    ollama_model_config,
)
from garage_rag.enrich.llama_xpc_provider import LlamaXPCLanguageModel


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
    # Never a bare model_id: LangExtract would pick the backend by regex on it.
    assert "model_id" not in captured
    assert "model_url" not in captured
    config = captured["config"]
    assert isinstance(config, lx.factory.ModelConfig)
    assert config.provider == OLLAMA_PROVIDER == "OllamaLanguageModel"
    assert config.model_id == DEFAULT_MODEL_ID
    assert config.provider_kwargs["model_url"] == "http://ollama.example:11434"
    assert captured["prompt_description"]
    assert captured["examples"]


def test_cloud_looking_model_id_still_pinned_to_ollama(monkeypatch) -> None:
    """``--model gemini-2.5-flash`` must not become a Gemini API call."""
    captured: dict = {}

    class Result:
        extractions: list = []

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)
    set_settings(Settings())
    try:
        extract_facts("some text", model_id="gemini-2.5-flash")
    finally:
        reset_settings()

    assert captured["config"].provider == "OllamaLanguageModel"
    assert captured["config"].model_id == "gemini-2.5-flash"
    assert "model_id" not in captured


@pytest.mark.parametrize("model_id", ["gemini-2.5-flash", "gpt-4o", "o1-mini", DEFAULT_MODEL_ID])
def test_langextract_resolves_pinned_config_to_ollama_provider(model_id: str) -> None:
    """End to end through LangExtract's own factory, not just our kwargs."""
    from langextract.providers.ollama import OllamaLanguageModel

    config = ollama_model_config(model_id, "http://127.0.0.1:11434")
    model = lx.factory.create_model(config)

    assert isinstance(model, OllamaLanguageModel)
    assert model._model_url == "http://127.0.0.1:11434"


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("http://localhost:11434", True),
        ("http://127.0.0.1:11434", True),
        ("http://127.1.2.3:11434", True),
        ("http://[::1]:11434", True),
        ("http://ollama.example:11434", False),
        ("http://10.0.0.5:11434", False),
    ],
)
def test_is_loopback_url(url: str, expected: bool) -> None:
    assert is_loopback_url(url) is expected


def test_extract_facts_routes_to_llama_xpc_when_requested(monkeypatch) -> None:
    captured: dict = {}

    grounded = _extraction("Acme Corp was founded in 1998.", start=0, end=31)

    class Result:
        extractions = [grounded]

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)

    extractions = extract_facts("Acme Corp was founded in 1998.", model_id="gemma2-2b", provider="llama_xpc")

    assert extractions == [grounded]
    assert isinstance(captured["model"], LlamaXPCLanguageModel)
    assert captured["model"].model_id == "gemma2-2b"
    assert "model_id" not in captured
    assert "model_url" not in captured


def test_extract_facts_rejects_unknown_provider() -> None:
    try:
        extract_facts("text", provider="bogus")
    except ValueError as exc:
        assert "bogus" in str(exc)
    else:
        raise AssertionError("expected ValueError for an unknown provider")


def test_llama_xpc_language_model_infers_via_chat_completion() -> None:
    fake_client = MagicMock()
    fake_client.chat_completion.return_value = {"choices": [{"message": {"content": '{"extractions": []}'}}]}

    model = LlamaXPCLanguageModel(model_id="gemma2-2b", client=fake_client)
    results = list(model.infer(["prompt one", "prompt two"]))

    assert len(results) == 2
    assert results[0][0].output == '{"extractions": []}'
    assert fake_client.chat_completion.call_count == 2
    first_call_kwargs = fake_client.chat_completion.call_args_list[0].kwargs
    assert first_call_kwargs["model"] == "gemma2-2b"
    assert first_call_kwargs["messages"] == [{"role": "user", "content": "prompt one"}]


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


def test_extract_and_store_facts_empty_content_clears_stale_facts(monkeypatch) -> None:
    document = Document(id=9, content="")
    called = False

    def fake_extract_facts(text, **kwargs):
        nonlocal called
        called = True
        return []

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    session = MagicMock()

    assert extract_and_store_facts(session, document) == []

    assert not called
    # The stale rows for a now-empty document are removed, not left behind.
    session.query.return_value.filter.return_value.delete.assert_called_once()
    assert not session.add_all.called


def test_remote_ollama_host_refuses_communications(monkeypatch) -> None:
    """A non-loopback ollama_host goes through the egress chokepoint."""
    document = Document(id=9, content="hi", corpus_class=CorpusClass.COMMUNICATION)
    called = False

    def fake_extract_facts(text, **kwargs):
        nonlocal called
        called = True
        return []

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    session = MagicMock()
    set_settings(Settings(ollama_host="http://ollama.example:11434"))
    try:
        with pytest.raises(EgressBlocked):
            extract_and_store_facts(session, document)
    finally:
        reset_settings()

    assert not called
    assert not session.query.called


def test_remote_ollama_host_allows_documents(monkeypatch) -> None:
    document = Document(id=9, content="hi", corpus_class=CorpusClass.DOCUMENT)
    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", lambda text, **kwargs: [])
    session = MagicMock()
    set_settings(Settings(ollama_host="http://ollama.example:11434"))
    try:
        assert extract_and_store_facts(session, document) == []
    finally:
        reset_settings()


def test_loopback_ollama_host_skips_egress_check(monkeypatch) -> None:
    """Local inference is not egress; communications are fine on loopback."""
    document = Document(id=9, content="hi", corpus_class=CorpusClass.COMMUNICATION)
    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", lambda text, **kwargs: [])
    session = MagicMock()
    set_settings(Settings(ollama_host="http://127.0.0.1:11434"))
    try:
        assert extract_and_store_facts(session, document) == []
    finally:
        reset_settings()


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
