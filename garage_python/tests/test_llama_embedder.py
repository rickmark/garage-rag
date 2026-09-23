"""Tests for LlamaXPCEmbedder and factory integration.

Pure-unit tests drive the embedder with hand-rolled clients; one test runs it
end to end against a fake llama-server on loopback. Nothing here needs the
real LlamaXPCService or a GGUF file -- that belongs in an integration test.
"""

from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.embed.base import Embedder, EmbeddingError
from garage_rag.embed.factory import get_embedder
from garage_rag.embed.llama_xpc import LlamaXPCEmbedder
from garage_rag.xpc.llama_xpc import LlamaXPCClient

DIMS = 6


class _EmbeddingsHandler(BaseHTTPRequestHandler):
    """Just enough of llama-server for the embedder: ``POST /v1/embeddings``."""

    seen: list[dict[str, Any]]

    def log_message(self, *_args: Any) -> None:
        pass

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.seen.append(body)
        if self.path != "/v1/embeddings":
            payload, status = {"error": {"message": "not found", "code": 404}}, 404
        else:
            inputs = body["input"]
            data = [
                {"object": "embedding", "index": i, "embedding": [float(i + 1)] + [0.0] * (DIMS - 1)}
                for i in range(len(inputs))
            ]
            payload, status = {"object": "list", "data": data, "model": body.get("model"), "usage": {}}, 200
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


@dataclass
class FakeServer:
    url: str
    seen: list[dict[str, Any]]


@pytest.fixture
def fake_server() -> Iterator[FakeServer]:
    seen: list[dict[str, Any]] = []
    handler = type("Handler", (_EmbeddingsHandler,), {"seen": seen})
    server = HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield FakeServer(url=f"http://127.0.0.1:{server.server_address[1]}", seen=seen)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_llama_embedder_against_fake_server(fake_server: FakeServer) -> None:
    embedder = LlamaXPCEmbedder(model_ref="bge-m3", client=LlamaXPCClient(fake_server.url, timeout=5.0))
    assert isinstance(embedder, Embedder)

    vectors = embedder.embed(["first", "second"])
    assert len(vectors) == 2
    assert vectors[0][0] == 1.0 and vectors[1][0] == 2.0
    assert all(len(v) == DIMS for v in vectors)
    assert embedder.probe_dims() == DIMS

    assert fake_server.seen[0] == {"input": ["first", "second"], "model": "bge-m3"}
    assert fake_server.seen[1] == {"input": ["dimension probe"], "model": "bge-m3"}


def test_embedder_factory_llama_xpc_uses_configured_host(fake_server: FakeServer) -> None:
    set_settings(Settings(llama_host=fake_server.url))
    try:
        embedder = get_embedder("llama_xpc", "bge-m3")
        assert isinstance(embedder, LlamaXPCEmbedder)
        assert embedder.model_ref == "bge-m3"
        assert embedder.client.base_url == fake_server.url
        assert embedder.probe_dims() == DIMS
    finally:
        reset_settings()


def test_llama_embedder_unreachable_server_is_embedding_error() -> None:
    """A connection failure comes out as the one EmbeddingError callers catch."""
    import socket

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    embedder = LlamaXPCEmbedder(model_ref="bge-m3", client=LlamaXPCClient(f"http://127.0.0.1:{port}", timeout=2.0))
    with pytest.raises(EmbeddingError, match="llama_xpc embed failed for bge-m3.*cannot reach"):
        embedder.embed(["hello"])


class _FailingClient:
    def embed_texts(self, texts, **kwargs):
        raise RuntimeError("XPC service crashed")


class _ShortClient:
    def embed_texts(self, texts, **kwargs):
        return [[0.1, 0.2]]  # one vector regardless of batch size


class _EmptyVectorClient:
    def embed_texts(self, texts, **kwargs):
        return [[] for _ in texts]


def test_llama_embedder_empty_batch_needs_no_client():
    embedder = LlamaXPCEmbedder(model_ref="default", client=_FailingClient())
    assert embedder.embed([]) == []
    assert isinstance(embedder, Embedder)


def test_llama_embedder_wraps_client_errors():
    failing_embedder = LlamaXPCEmbedder(model_ref="bad-model", client=_FailingClient())
    with pytest.raises(EmbeddingError, match="llama_xpc embed failed"):
        failing_embedder.embed(["hello"])


def test_llama_embedder_rejects_count_mismatch():
    embedder = LlamaXPCEmbedder(model_ref="short", client=_ShortClient())
    with pytest.raises(EmbeddingError, match="returned 1 vectors for 2 inputs"):
        embedder.embed(["a", "b"])


def test_llama_embedder_probe_rejects_empty_vector():
    embedder = LlamaXPCEmbedder(model_ref="empty", client=_EmptyVectorClient())
    with pytest.raises(EmbeddingError, match="probe returned an empty embedding"):
        embedder.probe_dims()


def test_embedding_error_is_one_class_everywhere():
    """cli.py and service/server.py catch the ollama spelling; it must be the same class."""
    from garage_rag.embed.llama_xpc import EmbeddingError as llama_error
    from garage_rag.embed.lmstudio import EmbeddingError as lmstudio_error
    from garage_rag.embed.ollama import EmbeddingError as ollama_error

    assert ollama_error is EmbeddingError
    assert lmstudio_error is EmbeddingError
    assert llama_error is EmbeddingError
