"""LM Studio embeddings over its OpenAI-compatible API, with httpx through the egress guard."""

from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.embed.base import EmbeddingError
from garage_rag.embed.lmstudio import LMStudioEmbedder


class FakeLMStudio:
    def __init__(self) -> None:
        self.requests: list[tuple[str, dict, dict]] = []
        # Statuses to answer with before succeeding.
        self.failures: list[int] = []
        self.reply: dict | None = None


@pytest.fixture
def server() -> Iterator[tuple[str, FakeLMStudio]]:
    state = FakeLMStudio()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def do_POST(self) -> None:
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            state.requests.append((self.path, dict(self.headers), body))
            if state.failures:
                status, payload = state.failures.pop(0), {"error": {"message": "model is loading"}}
            else:
                # Reversed on purpose: the client must order by "index".
                vectors = [{"index": i, "embedding": [float(i), 0.5]} for i in range(len(body["input"]))]
                status, payload = 200, state.reply or {"data": list(reversed(vectors))}
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{httpd.server_port}/v1"
    set_settings(Settings(lmstudio_host=url))
    try:
        yield url, state
    finally:
        reset_settings()
        httpd.shutdown()
        httpd.server_close()


def test_posts_one_batch_and_orders_vectors_by_index(server) -> None:
    _, state = server
    vectors = LMStudioEmbedder("text-embedding").embed(["a", "b", "c"])
    assert vectors == [[0.0, 0.5], [1.0, 0.5], [2.0, 0.5]]
    [(path, headers, body)] = state.requests
    assert path == "/v1/embeddings"
    assert body == {"model": "text-embedding", "input": ["a", "b", "c"]}
    assert "authorization" not in {k.lower() for k in headers}


def test_sends_the_configured_token_as_a_bearer(server) -> None:
    _, state = server
    LMStudioEmbedder("text-embedding", api_token="lm-token").embed(["a"])
    headers = {k.lower(): v for k, v in state.requests[0][1].items()}
    assert headers["authorization"] == "Bearer lm-token"


def test_reads_the_token_from_the_environment(server, monkeypatch) -> None:
    _, state = server
    monkeypatch.setenv("GARAGE_LMSTUDIO_API_TOKEN", "env-token")
    LMStudioEmbedder("text-embedding").embed(["a"])
    headers = {k.lower(): v for k, v in state.requests[0][1].items()}
    assert headers["authorization"] == "Bearer env-token"


def test_server_error_message_is_surfaced(server) -> None:
    _, state = server
    state.failures = [400]
    with pytest.raises(EmbeddingError, match="HTTP 400: model is loading"):
        LMStudioEmbedder("text-embedding").embed(["a"])
    assert len(state.requests) == 1  # a 400 is not retried


def test_transient_failures_are_retried_twice(server) -> None:
    _, state = server
    state.failures = [503, 429]
    with patch("garage_rag.embed.lmstudio.time.sleep"):
        assert LMStudioEmbedder("text-embedding").embed(["a"]) == [[0.0, 0.5]]
    assert len(state.requests) == 3


def test_gives_up_after_two_retries(server) -> None:
    _, state = server
    state.failures = [500, 500, 500]
    with patch("garage_rag.embed.lmstudio.time.sleep"), pytest.raises(EmbeddingError, match="HTTP 500"):
        LMStudioEmbedder("text-embedding").embed(["a"])
    assert len(state.requests) == 3


def test_malformed_reply_is_an_embedding_error(server) -> None:
    _, state = server
    state.reply = {"object": "list"}
    with pytest.raises(EmbeddingError, match="no 'data' list"):
        LMStudioEmbedder("text-embedding").embed(["a"])
