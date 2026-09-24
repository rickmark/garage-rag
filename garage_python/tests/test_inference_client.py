"""``InferenceClient`` against mock LM Studio, Ollama and llama-server HTTP servers.

Each fake answers with the shapes the M3 probe recorded for the real server
(validation/m3-report.md, "OpenAI-compatible API probe"), including the
awkward ones: LM Studio's HTTP 200 for an unknown route, its HTTP 400 for
``response_format: json_object``, its 404 ``model_not_found`` on unload, and
the load/unload/download objects of its native REST API. Every request is
recorded, so the wire format is asserted, not just the return values.
"""

from __future__ import annotations

import json
import socket
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import pytest

from garage_rag.config import Settings
from garage_rag.db.models import CorpusClass
from garage_rag.inference import (
    Backend,
    BackendKind,
    ChatResult,
    InferenceAuthError,
    InferenceBadReply,
    InferenceClient,
    InferenceError,
    InferenceErrorBody,
    InferenceHTTPError,
    InferenceRefused,
    InferenceUnreachable,
    InferenceUnsupported,
    json_schema_format,
)
from garage_rag.net.egress import EgressBlocked

# A route handler gets the decoded body and returns (status, JSON payload) or (status, raw bytes).
Reply = tuple[int, Any]
Route = Callable[[Any], Reply]


@dataclass
class Seen:
    method: str
    path: str
    body: Any
    headers: dict[str, str]


@dataclass
class FakeServer:
    kind: str
    url: str = ""
    routes: dict[tuple[str, str], Route] = field(default_factory=dict)
    seen: list[Seen] = field(default_factory=list)

    def route(self, method: str, path: str, handler: Route) -> None:
        self.routes[(method, path)] = handler

    def unknown(self, method: str, path: str) -> Reply:
        """How each real server answers a route it does not have."""
        if self.kind == "lmstudio":
            return 200, {"error": f"Unexpected endpoint or method. ({method} {path})"}
        if self.kind == "ollama":
            return 404, b"404 page not found"
        return 404, {"error": {"code": 404, "message": "File Not Found", "type": "not_found_error"}}

    @property
    def paths(self) -> list[tuple[str, str]]:
        return [(s.method, s.path) for s in self.seen]


def _handler_for(server: FakeServer) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args: Any) -> None:
            pass

        def _dispatch(self, method: str) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            body = json.loads(raw) if raw else None
            server.seen.append(Seen(method, self.path, body, {k.lower(): v for k, v in self.headers.items()}))
            handler = server.routes.get((method, self.path))
            status, payload = handler(body) if handler else server.unknown(method, self.path)
            data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain" if isinstance(payload, bytes) else "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802 - http.server API
            self._dispatch("GET")

        def do_POST(self) -> None:  # noqa: N802 - http.server API
            self._dispatch("POST")

    return Handler


@pytest.fixture
def serve() -> Iterator[Callable[[str], FakeServer]]:
    started: list[tuple[ThreadingHTTPServer, threading.Thread]] = []

    def start(kind: str) -> FakeServer:
        fake = FakeServer(kind)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), _handler_for(fake))
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        started.append((httpd, thread))
        fake.url = f"http://127.0.0.1:{httpd.server_address[1]}"
        return fake

    yield start
    for httpd, thread in started:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=5)


def _client(fake: FakeServer, **backend: Any) -> InferenceClient:
    return InferenceClient(Backend(BackendKind(fake.kind), fake.url, timeout=5.0, **backend))


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# ---- server personalities ------------------------------------------------------


def _openai_embeddings(dims: int = 4) -> Route:
    """``/v1/embeddings``: items deliberately returned in reverse order, as a server may."""

    def reply(body: Any) -> Reply:
        items = [
            {"object": "embedding", "index": i, "embedding": [float(i + 1)] + [0.0] * (dims - 1)}
            for i in range(len(body["input"]))
        ]
        return 200, {
            "object": "list",
            "data": list(reversed(items)),
            "model": body.get("model"),
            "usage": {"prompt_tokens": 0, "total_tokens": 0},
        }

    return reply


def _chat_echo(body: Any) -> Reply:
    return 200, {
        "id": "chatcmpl-1",
        "object": "chat.completion",
        "model": body.get("model"),
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "echo: " + body["messages"][-1]["content"]},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 11, "completion_tokens": 3, "total_tokens": 14},
    }


def _lmstudio_chat(body: Any) -> Reply:
    """LM Studio refuses ``json_object``; ``json_schema`` and ``text`` are fine."""
    fmt = body.get("response_format")
    if fmt is not None and fmt.get("type") not in ("json_schema", "text"):
        return 400, {"error": "'response_format.type' must be 'json_schema' or 'text'"}
    return _chat_echo(body)


def lmstudio(serve: Callable[[str], FakeServer]) -> FakeServer:
    fake = serve("lmstudio")
    fake.route("GET", "/v1/models", lambda _b: (200, {"object": "list", "data": [{"id": "google/gemma-3-4b"}]}))
    fake.route("POST", "/v1/embeddings", _openai_embeddings(768))
    fake.route("POST", "/v1/chat/completions", _lmstudio_chat)
    return fake


def ollama(serve: Callable[[str], FakeServer]) -> FakeServer:
    fake = serve("ollama")
    fake.route(
        "GET",
        "/v1/models",
        lambda _b: (200, {"object": "list", "data": [{"id": "llama4:latest"}, {"id": "gemma2:2b"}]}),
    )
    fake.route(
        "POST",
        "/api/embed",
        lambda body: (
            200,
            {
                "model": body["model"],
                "embeddings": [[float(i + 10), 0.0, 0.0] for i in range(len(body["input"]))],
                "total_duration": 1,
                "prompt_eval_count": 2,
            },
        ),
    )
    fake.route("POST", "/v1/embeddings", _openai_embeddings(3))
    fake.route("POST", "/v1/chat/completions", _chat_echo)
    return fake


# ---- backend descriptor -------------------------------------------------------


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("http://localhost:1234/v1", "http://localhost:1234"),
        ("http://localhost:1234/v1/", "http://localhost:1234"),
        ("http://localhost:1234", "http://localhost:1234"),
        ("localhost:11434", "http://localhost:11434"),
        ("https://gpu.example/lmstudio/v1", "https://gpu.example/lmstudio"),
    ],
)
def test_base_url_is_the_server_root(url: str, expected: str) -> None:
    assert Backend(BackendKind.LMSTUDIO, url).base_url == expected


def test_from_settings_reads_each_host_and_the_lmstudio_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GARAGE_LMSTUDIO_API_TOKEN", "secret")
    settings = Settings(ollama_host="http://127.0.0.1:11500", lmstudio_host="http://127.0.0.1:1300/v1")
    lm = Backend.from_settings("lmstudio", settings)
    assert (lm.kind, lm.base_url, lm.token) == (BackendKind.LMSTUDIO, "http://127.0.0.1:1300", "secret")
    assert "secret" not in repr(lm)
    ol = Backend.from_settings("ollama", settings)
    assert (ol.base_url, ol.token, ol.ollama_embed_route) == ("http://127.0.0.1:11500", None, "native")
    assert Backend.from_settings("llama_xpc", settings).base_url == "http://127.0.0.1:8790"


def test_is_local() -> None:
    assert Backend(BackendKind.OLLAMA, "http://localhost:11434").is_local
    assert not Backend(BackendKind.OLLAMA, "http://gpu.example:11434").is_local


# ---- destinations (the seam the egress guard plugs into) ------------------------


def test_llama_xpc_is_loopback_only() -> None:
    with pytest.raises(InferenceRefused, match="loopback") as info:
        InferenceClient(Backend(BackendKind.LLAMA_XPC, "http://gpu.example:8790"))
    assert info.value.status_code == 400


@pytest.mark.parametrize("kind", ["ollama", "lmstudio"])
@pytest.mark.parametrize("url", ["http://gpu.example:11434", "http://10.0.0.5:1234/v1", "http://127.example.com:1234"])
def test_an_unapproved_host_is_refused(kind: str, url: str) -> None:
    """Refused by the egress guard before any connection exists."""
    with pytest.raises(EgressBlocked, match="not an approved destination") as info:
        InferenceClient(Backend(BackendKind(kind), url), settings=Settings())
    assert isinstance(info.value, InferenceRefused)
    assert info.value.status_code == 400


def test_the_configured_remote_host_is_approved_but_not_for_communications() -> None:
    settings = Settings(ollama_host="http://gpu.example:11434", lmstudio_host="http://lm.example:1234/v1")
    for kind, url in (("ollama", "http://gpu.example:11434"), ("lmstudio", "http://lm.example:1234/v1")):
        InferenceClient(Backend(BackendKind(kind), url), settings=settings)
        InferenceClient(Backend(BackendKind(kind), url), corpus_class=CorpusClass.DOCUMENT, settings=settings)
        with pytest.raises(InferenceRefused, match="communications may never be sent off this machine"):
            InferenceClient(Backend(BackendKind(kind), url), corpus_class=CorpusClass.COMMUNICATION, settings=settings)
    # Each backend's approval is the origin, not the kind: Ollama's host is approved for LM Studio too.
    with pytest.raises(InferenceRefused):
        InferenceClient(Backend(BackendKind.OLLAMA, "http://elsewhere.example:11434"), settings=settings)


def test_communications_go_to_loopback(serve) -> None:
    fake = ollama(serve)
    client = InferenceClient(Backend(BackendKind.OLLAMA, fake.url), corpus_class=CorpusClass.COMMUNICATION)
    assert client.list_models() == ["llama4:latest", "gemma2:2b"]


def test_environment_proxies_are_ignored(monkeypatch: pytest.MonkeyPatch, serve) -> None:
    fake = lmstudio(serve)
    for name in ("http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"):
        monkeypatch.setenv(name, "http://proxy.invalid:3128")
    monkeypatch.delenv("no_proxy", raising=False)
    monkeypatch.delenv("NO_PROXY", raising=False)
    assert _client(fake).list_models() == ["google/gemma-3-4b"]


# ---- transport and HTTP errors ------------------------------------------------


def test_unreachable_server() -> None:
    client = InferenceClient(Backend(BackendKind.OLLAMA, f"http://127.0.0.1:{_free_port()}", timeout=2.0))
    with pytest.raises(InferenceUnreachable, match="cannot reach Ollama") as info:
        client.list_models()
    assert info.value.status_code == 503


def test_timeout_is_unreachable(serve) -> None:
    fake = serve("llama_xpc")

    def slow(_body: Any) -> Reply:
        time.sleep(1.0)
        return 200, {"data": []}

    fake.route("GET", "/v1/models", slow)
    client = InferenceClient(Backend(BackendKind.LLAMA_XPC, fake.url, timeout=0.2))
    with pytest.raises(InferenceUnreachable, match="timed out"):
        client.list_models()


def test_lmstudio_unknown_route_is_an_error_despite_http_200(serve) -> None:
    fake = lmstudio(serve)
    with pytest.raises(InferenceErrorBody, match="Unexpected endpoint or method") as info:
        _client(fake)._call("POST", "/api/embed", {"model": "m", "input": ["x"]})
    assert info.value.status_code == 200
    assert isinstance(info.value, InferenceHTTPError)


def test_ollama_native_embed_pointed_at_lmstudio_fails_cleanly(serve) -> None:
    """The probe's case: Ollama's route on an LM Studio port must not look like 'no data'."""
    fake = lmstudio(serve)
    client = InferenceClient(Backend(BackendKind.OLLAMA, fake.url))
    with pytest.raises(InferenceErrorBody, match="Unexpected endpoint"):
        client.embed(["x"], "nomic")


def test_non_2xx_with_a_plain_text_body(serve) -> None:
    fake = ollama(serve)
    with pytest.raises(InferenceHTTPError, match="404 page not found") as info:
        _client(fake)._call("GET", "/nope")
    assert info.value.status_code == 404


def test_openai_shaped_error_keeps_message_and_type(serve) -> None:
    fake = ollama(serve)
    fake.route(
        "POST",
        "/v1/embeddings",
        lambda _b: (501, {"error": {"message": "This server does not support embeddings.", "type": "api_error"}}),
    )
    client = _client(fake, ollama_embed_route="openai")
    with pytest.raises(InferenceHTTPError, match="does not support embeddings") as info:
        client.embed(["x"], "llama4")
    assert (info.value.status_code, info.value.error_type) == (501, "api_error")


def test_2xx_non_json_is_a_bad_reply(serve) -> None:
    fake = serve("llama_xpc")
    fake.route("GET", "/v1/models", lambda _b: (200, b"<html>hi</html>"))
    with pytest.raises(InferenceBadReply, match="non-JSON") as info:
        _client(fake).list_models()
    assert info.value.status_code == 502


@pytest.mark.parametrize("status", [401, 403])
def test_auth_failures_name_the_token_settings(serve, status: int) -> None:
    fake = lmstudio(serve)
    fake.route("GET", "/v1/models", lambda _b: (status, {"error": {"message": "Invalid API token"}}))
    with pytest.raises(InferenceAuthError, match="GARAGE_LMSTUDIO_API_TOKEN") as info:
        _client(fake).list_models()
    assert info.value.status_code == status
    assert "Invalid API token" in str(info.value)


def test_auth_failure_without_a_body(serve) -> None:
    fake = lmstudio(serve)
    fake.route("GET", "/api/v1/models", lambda _b: (401, b""))
    with pytest.raises(InferenceAuthError, match="HTTP 401"):
        _client(fake).lmstudio_models()


def test_bearer_token_is_sent_only_when_configured(serve) -> None:
    fake = lmstudio(serve)
    _client(fake, token="tok").list_models()
    _client(fake).list_models()
    assert fake.seen[0].headers["authorization"] == "Bearer tok"
    assert "authorization" not in fake.seen[1].headers


# ---- models ----------------------------------------------------------------------


def test_list_models_and_has_model(serve) -> None:
    fake = ollama(serve)
    client = _client(fake)
    assert client.list_models() == ["llama4:latest", "gemma2:2b"]
    assert client.has_model("gemma2:2b")
    assert client.has_model("llama4")  # Ollama's implicit :latest
    assert not client.has_model("gemma2")
    assert fake.paths[0] == ("GET", "/v1/models")


def test_untagged_names_match_exactly_elsewhere(serve) -> None:
    fake = lmstudio(serve)
    fake.route("GET", "/v1/models", lambda _b: (200, {"data": [{"id": "foo:latest"}]}))
    assert not _client(fake).has_model("foo")


def test_list_models_without_data_is_a_bad_reply(serve) -> None:
    fake = serve("llama_xpc")
    fake.route("GET", "/v1/models", lambda _b: (200, {"models": []}))
    with pytest.raises(InferenceBadReply, match="no 'data' list"):
        _client(fake).list_models()


# ---- embeddings ------------------------------------------------------------------


def test_lmstudio_embeddings_in_input_order_without_dimensions(serve) -> None:
    fake = lmstudio(serve)
    vectors = _client(fake).embed(["a", "b", "c"], "text-embedding-nomic-embed-text-v1.5")
    assert [v[0] for v in vectors] == [1.0, 2.0, 3.0]
    assert all(len(v) == 768 for v in vectors)
    assert fake.seen[0].path == "/v1/embeddings"
    assert fake.seen[0].body == {"input": ["a", "b", "c"], "model": "text-embedding-nomic-embed-text-v1.5"}


def test_ollama_embeddings_default_to_the_native_route(serve) -> None:
    fake = ollama(serve)
    vectors = _client(fake).embed(["a", "b"], "nomic-embed-text")
    assert vectors == [[10.0, 0.0, 0.0], [11.0, 0.0, 0.0]]
    assert fake.seen[0].path == "/api/embed"
    assert fake.seen[0].body == {"model": "nomic-embed-text", "input": ["a", "b"]}


def test_ollama_embeddings_on_the_openai_route_when_switched(serve) -> None:
    fake = ollama(serve)
    vectors = _client(fake, ollama_embed_route="openai").embed(["a", "b"], "nomic-embed-text")
    assert [v[0] for v in vectors] == [1.0, 2.0]
    assert fake.seen[0].path == "/v1/embeddings"


def test_ollama_native_embeddings_need_a_model(serve) -> None:
    fake = ollama(serve)
    with pytest.raises(ValueError, match="model"):
        _client(fake).embed(["a"])
    assert fake.seen == []


def test_empty_batch_sends_nothing(serve) -> None:
    fake = ollama(serve)
    assert _client(fake).embed([], "m") == []
    assert fake.seen == []


@pytest.mark.parametrize("kind", ["lmstudio", "ollama"])
def test_vector_count_mismatch_is_a_bad_reply(serve, kind: str) -> None:
    fake = serve(kind)
    fake.route("POST", "/v1/embeddings", lambda _b: (200, {"data": [{"index": 0, "embedding": [1.0]}]}))
    fake.route("POST", "/api/embed", lambda _b: (200, {"embeddings": [[1.0]]}))
    with pytest.raises(InferenceBadReply, match="1 vectors for 2 inputs"):
        _client(fake).embed(["a", "b"], "m")


@pytest.mark.parametrize(
    "data",
    [["not an object"], [{"embedding": [1.0]}], [{"index": 0}]],
    ids=["non-object item", "no index", "no embedding"],
)
def test_malformed_embedding_item_is_a_bad_reply(serve, data) -> None:
    fake = lmstudio(serve)
    fake.route("POST", "/v1/embeddings", lambda _b: (200, {"data": data}))
    with pytest.raises(InferenceBadReply, match="malformed embedding item"):
        _client(fake).embed(["a"], "m")


# ---- chat ------------------------------------------------------------------------


@pytest.mark.parametrize("personality", [lmstudio, ollama])
def test_chat_body_and_result(serve, personality) -> None:
    fake = personality(serve)
    result = _client(fake).chat(
        [{"role": "system", "content": "be brief"}, {"role": "user", "content": "hi"}],
        "some-model",
        max_tokens=32,
        temperature=0.1,
    )
    assert result == ChatResult(
        text="echo: hi", finish_reason="stop", prompt_tokens=11, completion_tokens=3, model="some-model"
    )
    assert fake.seen[0].path == "/v1/chat/completions"
    assert fake.seen[0].body == {
        "messages": [{"role": "system", "content": "be brief"}, {"role": "user", "content": "hi"}],
        "model": "some-model",
        "max_tokens": 32,
        "temperature": 0.1,
    }


def test_lmstudio_rejects_json_object_with_400(serve) -> None:
    fake = lmstudio(serve)
    with pytest.raises(InferenceHTTPError, match="must be 'json_schema' or 'text'") as info:
        _client(fake).chat([{"role": "user", "content": "x"}], "m", response_format={"type": "json_object"})
    assert info.value.status_code == 400


def test_json_schema_format_is_accepted_by_lmstudio(serve) -> None:
    fake = lmstudio(serve)
    fmt = json_schema_format("facts", {"type": "object", "properties": {"facts": {"type": "array"}}})
    _client(fake).chat([{"role": "user", "content": "x"}], "m", response_format=fmt)
    assert fake.seen[0].body["response_format"] == {
        "type": "json_schema",
        "json_schema": {
            "name": "facts",
            "strict": True,
            "schema": {"type": "object", "properties": {"facts": {"type": "array"}}},
        },
    }


def test_ollama_accepts_json_object(serve) -> None:
    fake = ollama(serve)
    _client(fake).chat([{"role": "user", "content": "x"}], "m", response_format={"type": "json_object"})
    assert fake.seen[0].body["response_format"] == {"type": "json_object"}


def test_null_content_is_empty_text_and_missing_usage_is_none(serve) -> None:
    fake = serve("llama_xpc")
    fake.route("POST", "/v1/chat/completions", lambda _b: (200, {"choices": [{"message": {"content": None}}]}))
    result = _client(fake).chat([{"role": "user", "content": "x"}])
    assert (result.text, result.prompt_tokens, result.finish_reason) == ("", None, None)


def test_chat_without_choices_is_a_bad_reply(serve) -> None:
    fake = serve("llama_xpc")
    fake.route("POST", "/v1/chat/completions", lambda _b: (200, {"choices": []}))
    with pytest.raises(InferenceBadReply, match="malformed reply"):
        _client(fake).chat([{"role": "user", "content": "x"}])


# ---- LM Studio model management ---------------------------------------------------

_CATALOG = {
    "models": [
        {
            "type": "embedding",
            "key": "text-embedding-nomic-embed-text-v1.5",
            "loaded_instances": [],
            "max_context_length": 2048,
            "format": "gguf",
            "quantization": {"name": "Q4_K_M", "bits_per_weight": 4},
        },
        {
            "type": "llm",
            "key": "google/gemma-3-4b",
            "loaded_instances": [{"id": "google/gemma-3-4b", "config": {"context_length": 131072}}],
            "max_context_length": 131072,
            "format": "mlx",
        },
    ]
}


def test_lmstudio_models(serve) -> None:
    fake = lmstudio(serve)
    fake.route("GET", "/api/v1/models", lambda _b: (200, _CATALOG))
    embedding, llm = _client(fake).lmstudio_models()
    assert (embedding.key, embedding.type, embedding.is_loaded, embedding.max_context_length) == (
        "text-embedding-nomic-embed-text-v1.5",
        "embedding",
        False,
        2048,
    )
    assert llm.is_loaded
    assert llm.loaded_instances[0].id == "google/gemma-3-4b"
    assert llm.loaded_instances[0].config == {"context_length": 131072}
    assert embedding.raw["quantization"]["name"] == "Q4_K_M"


def test_load_model_reads_back_the_applied_config(serve) -> None:
    """MLX models ignore ``context_length``; the result says what was applied."""
    fake = lmstudio(serve)
    fake.route(
        "POST",
        "/api/v1/models/load",
        lambda body: (
            200,
            {
                "type": "llm",
                "instance_id": body["model"],
                "load_time_seconds": 7.248,
                "status": "loaded",
                "load_config": {"context_length": 131072, "parallel": 4},
            },
        ),
    )
    result = _client(fake).load_model("google/gemma-3-4b", context_length=8192)
    assert fake.seen[0].body == {"model": "google/gemma-3-4b", "echo_load_config": True, "context_length": 8192}
    assert result.instance_id == "google/gemma-3-4b"
    assert (result.type, result.status, result.load_time_seconds) == ("llm", "loaded", 7.248)
    assert result.load_config["context_length"] == 131072


def test_load_model_omits_context_length_when_unset(serve) -> None:
    fake = lmstudio(serve)
    fake.route("POST", "/api/v1/models/load", lambda b: (200, {"instance_id": b["model"], "status": "loaded"}))
    _client(fake).load_model("m")
    assert fake.seen[0].body == {"model": "m", "echo_load_config": True}


def test_unload_model(serve) -> None:
    fake = lmstudio(serve)
    fake.route("POST", "/api/v1/models/unload", lambda b: (200, {"instance_id": b["instance_id"]}))
    assert _client(fake).unload_model("google/gemma-3-4b") == "google/gemma-3-4b"
    assert fake.seen[0].body == {"instance_id": "google/gemma-3-4b"}


def test_unload_unknown_instance_is_404_model_not_found(serve) -> None:
    fake = lmstudio(serve)
    fake.route(
        "POST",
        "/api/v1/models/unload",
        lambda b: (
            404,
            {
                "error": {
                    "type": "model_not_found",
                    "message": f"Model with instance identifier '{b['instance_id']}' is not loaded.",
                }
            },
        ),
    )
    with pytest.raises(InferenceHTTPError, match="is not loaded") as info:
        _client(fake).unload_model("no-such-instance")
    assert (info.value.status_code, info.value.error_type) == (404, "model_not_found")


def test_download_model_returns_the_job(serve) -> None:
    fake = lmstudio(serve)
    fake.route(
        "POST",
        "/api/v1/models/download",
        lambda _b: (
            200,
            {"job_id": "job_1", "status": "downloading", "total_size_bytes": 2_500_000_000, "started_at": "2026-09-23"},
        ),
    )
    job = _client(fake).download_model("google/gemma-3-4b", quantization="Q4_K_M")
    assert fake.seen[0].body == {"model": "google/gemma-3-4b", "quantization": "Q4_K_M"}
    assert (job.job_id, job.status, job.total_size_bytes, job.started_at) == (
        "job_1",
        "downloading",
        2_500_000_000,
        "2026-09-23",
    )
    assert not job.finished


def test_download_of_a_model_already_on_disk(serve) -> None:
    fake = lmstudio(serve)
    fake.route("POST", "/api/v1/models/download", lambda _b: (200, {"status": "already_downloaded"}))
    job = _client(fake).download_model("google/gemma-3-4b")
    assert fake.seen[0].body == {"model": "google/gemma-3-4b"}
    assert (job.job_id, job.status, job.finished) == (None, "already_downloaded", True)


def test_download_reply_without_status_is_a_bad_reply(serve) -> None:
    fake = lmstudio(serve)
    fake.route("POST", "/api/v1/models/download", lambda _b: (200, {"job_id": "j"}))
    with pytest.raises(InferenceBadReply):
        _client(fake).download_model("m")


@pytest.mark.parametrize("personality", [ollama])
def test_model_management_is_lmstudio_only(serve, personality) -> None:
    fake = personality(serve)
    client = _client(fake)
    for call in (
        client.lmstudio_models,
        lambda: client.load_model("m"),
        lambda: client.unload_model("m"),
        lambda: client.download_model("m"),
    ):
        with pytest.raises(InferenceUnsupported) as info:
            call()
        assert info.value.status_code == 501
    assert fake.seen == []


def test_every_error_is_an_inference_error() -> None:
    for cls in (
        InferenceUnreachable,
        InferenceHTTPError,
        InferenceAuthError,
        InferenceErrorBody,
        InferenceBadReply,
        InferenceUnsupported,
        InferenceRefused,
    ):
        assert issubclass(cls, InferenceError)


# ---- retries ---------------------------------------------------------------------


def test_retries_transient_statuses_then_succeeds(serve, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("garage_rag.inference.client.time.sleep", lambda _s: None)
    fake = lmstudio(serve)
    replies = iter([(503, {"error": "loading"}), (429, {"error": "busy"})])
    fake.route("GET", "/v1/models", lambda _b: next(replies, (200, {"data": [{"id": "m"}]})))
    assert _client(fake, max_retries=2).list_models() == ["m"]
    assert len(fake.seen) == 3


def test_no_retries_by_default_and_4xx_is_never_retried(serve, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("garage_rag.inference.client.time.sleep", lambda _s: None)
    fake = lmstudio(serve)
    fake.route("GET", "/v1/models", lambda _b: (503, {"error": "loading"}))
    with pytest.raises(InferenceHTTPError):
        _client(fake).list_models()
    assert len(fake.seen) == 1
    fake.route("GET", "/v1/models", lambda _b: (400, {"error": "bad"}))
    with pytest.raises(InferenceHTTPError):
        _client(fake, max_retries=2).list_models()
    assert len(fake.seen) == 2


def test_unreachable_is_retried_then_raised(monkeypatch: pytest.MonkeyPatch) -> None:
    sleeps: list[float] = []
    monkeypatch.setattr("garage_rag.inference.client.time.sleep", sleeps.append)
    client = InferenceClient(
        Backend(BackendKind.OLLAMA, f"http://127.0.0.1:{_free_port()}", timeout=2.0, max_retries=2)
    )
    with pytest.raises(InferenceUnreachable):
        client.list_models()
    assert sleeps == [0.5, 1.0]
