from __future__ import annotations

import hashlib
import json
import sys
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import MagicMock

import pytest

from garage_rag.config import NonLoopbackHost, Settings, reset_settings, set_settings
from garage_rag.db.models import Chunk, CorpusClass, Document, Fact
from garage_rag.enrich import langextract as lx
from garage_rag.enrich.facts import (
    DEFAULT_MODEL_ID,
    chunk_for_fact,
    extract_and_store_facts,
    extract_facts,
    facts_from_extractions,
    refuse_cloud_model_id,
)
from garage_rag.enrich.llama_xpc_provider import LlamaXPCLanguageModel
from garage_rag.enrich.ollama_provider import OllamaLanguageModel


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
    set_settings(Settings(ollama_host="http://127.0.0.1:11434"))
    try:
        extractions = extract_facts("Acme Corp was founded in 1998.")
    finally:
        reset_settings()

    assert extractions == [grounded]
    model = captured["model"]
    assert isinstance(model, OllamaLanguageModel)
    assert model.model_id == DEFAULT_MODEL_ID
    assert model.model_url == "http://127.0.0.1:11434"
    assert captured["prompt_description"]
    assert captured["examples"]


@pytest.mark.parametrize(
    "model_id", ["gemini-2.5-flash", "Gemini-Pro", "gpt-4o", "gpt-5", "gpt-3.5-turbo", "o1-mini", "o3", "claude-x"]
)
@pytest.mark.parametrize("provider", ["ollama", "llama_xpc"])
def test_cloud_model_id_is_refused(monkeypatch, model_id: str, provider: str) -> None:
    """``--model gemini-2.5-flash`` is a clear error, never a request to anything."""

    def fail(**kwargs):
        raise AssertionError("extract must not run for a cloud model id")

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fail)
    with pytest.raises(ValueError, match="cloud-hosted model"):
        extract_facts("some text", model_id=model_id, provider=provider)


@pytest.mark.parametrize("model_id", [DEFAULT_MODEL_ID, "gemma2-2b", "gpt-oss:20b", "llama3.2:1b", "qwen2.5:7b"])
def test_local_model_ids_are_accepted(model_id: str) -> None:
    refuse_cloud_model_id(model_id)


def test_upstream_langextract_is_never_imported() -> None:
    """The vendored subset stands alone; upstream's package routes to Google and OpenAI."""
    import garage_rag.enrich.facts  # noqa: F401

    assert not [name for name in sys.modules if name == "langextract" or name.startswith("langextract.")]


# ---- end to end, against fake local servers ---------------------------------

_DOCUMENT = "Acme Corp was founded in 1998 by Jane Doe. The company is headquartered in Austin, Texas."
_ANSWER = json.dumps(
    {
        "extractions": [
            {"fact": "Acme Corp was founded in 1998 by Jane Doe."},
            {"fact": "The company is headquartered in Austin, Texas."},
            {"fact": "Something the document never says."},
        ]
    }
)


@pytest.fixture
def local_model_server() -> Iterator[tuple[str, list[tuple[str, dict]]]]:
    """A loopback server answering both Ollama's and llama-server's routes."""
    requests: list[tuple[str, dict]] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def do_POST(self) -> None:
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            requests.append((self.path, body))
            if self.path == "/api/generate":
                reply = {"response": _ANSWER, "done": True}
            elif self.path == "/api/chat":
                reply = {"message": {"role": "assistant", "content": _ANSWER}, "done": True}
            else:
                reply = {"choices": [{"message": {"role": "assistant", "content": _ANSWER}}]}
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    set_settings(Settings(ollama_host=url, llama_host=url))
    try:
        yield url, requests
    finally:
        reset_settings()
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize(
    ("provider", "model_id", "route"),
    [
        ("ollama", DEFAULT_MODEL_ID, "/api/generate"),
        ("ollama", "gpt-oss:20b", "/api/chat"),
        ("llama_xpc", "gemma2-2b", "/v1/chat/completions"),
    ],
)
def test_extract_facts_end_to_end(local_model_server, provider: str, model_id: str, route: str) -> None:
    """A real run through the vendored LangExtract: prompt, parse, align, ground."""
    _, requests = local_model_server

    extractions = extract_facts(_DOCUMENT, model_id=model_id, provider=provider)

    assert [(e.extraction_text, e.char_interval.start_pos, e.char_interval.end_pos) for e in extractions] == [
        ("Acme Corp was founded in 1998 by Jane Doe.", 0, 42),
        ("The company is headquartered in Austin, Texas.", 43, 89),
    ]
    assert [path for path, _ in requests] == [route]
    body = requests[0][1]
    assert body["model"] == model_id
    prompt = body["prompt"] if route == "/api/generate" else body["messages"][-1]["content"]
    assert prompt.startswith("Extract every standalone fact stated in this document.")
    assert prompt.rstrip().endswith("A:") and _DOCUMENT in prompt
    if provider == "ollama":
        assert body["think"] is False
        assert body["options"] == {"keep_alive": 300, "temperature": 0.1, "num_ctx": 2048}
    if route == "/api/generate":
        assert body["format"] == "json"


def test_ollama_model_not_found_is_a_config_error() -> None:
    client = MagicMock()
    client.post.return_value = MagicMock(status_code=404)
    model = OllamaLanguageModel("missing:1b", "http://127.0.0.1:11434", client=client)
    with pytest.raises(lx.exceptions.InferenceConfigError, match="ollama run missing:1b"):
        list(model.infer(["prompt"]))


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


@pytest.mark.parametrize("corpus_class", [CorpusClass.COMMUNICATION, CorpusClass.DOCUMENT])
def test_remote_ollama_host_is_refused_for_every_class(monkeypatch, corpus_class: CorpusClass) -> None:
    """Off-box is not a policy decision per class any more: nothing goes there."""
    document = Document(id=9, content="hi", corpus_class=corpus_class)
    called = False

    def fake_extract_facts(text, **kwargs):
        nonlocal called
        called = True
        return []

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    session = MagicMock()
    with pytest.raises(NonLoopbackHost):
        extract_and_store_facts(session, document, model_url="http://ollama.example:11434")

    assert not called
    assert not session.query.called


def test_loopback_ollama_host_takes_communications(monkeypatch) -> None:
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
