"""HTTP client for the llama.cpp server hosted by the app's LlamaXPCService.

The Swift ``LlamaXPCService`` loads models over XPC (the app drives that) and
serves a llama-server / OpenAI-compatible HTTP API on loopback, at
``settings.llama_host`` (default :data:`DEFAULT_LLAMA_HTTP_URL`).

Embeddings, chat and the model list are the shared OpenAI-shaped routes of
:class:`garage_rag.inference.InferenceClient`; :class:`LlamaXPCClient` adds
the llama-server-only routes (health, props, raw completion, tokenizer,
rerank). The transport refuses any non-loopback ``llama_host`` and never uses
an HTTP proxy, so content handed to this client cannot leave the machine.

Model load/unload are not HTTP operations here; they go over NSXPC from the
app; the inherited LM Studio management methods raise
:class:`~garage_rag.inference.InferenceUnsupported` here.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

from garage_rag.config import get_settings
from garage_rag.inference.client import (
    Backend,
    BackendKind,
    InferenceBadReply,
    InferenceClient,
    InferenceError,
    is_loopback_url,
)

__all__ = [
    "DEFAULT_LLAMA_HTTP_URL",
    "LlamaXPCClient",
    "LlamaXPCError",
    "is_loopback_url",
]

# Where LlamaXPCService binds its HTTP API; mirrored by ``Settings.llama_host``.
DEFAULT_LLAMA_HTTP_URL = "http://127.0.0.1:8790"

# Kept for callers that catch the old name; every client error is an InferenceError.
LlamaXPCError = InferenceError


class LlamaXPCClient(InferenceClient):
    """:class:`InferenceClient` for LlamaXPCService, plus its llama-server-only routes."""

    def __init__(self, base_url: str | None = None, *, timeout: float = 600.0) -> None:
        super().__init__(Backend(BackendKind.LLAMA_XPC, base_url or get_settings().llama_host, timeout=timeout))

    # ---- status ----------------------------------------------------------

    def health(self) -> dict[str, Any]:
        """``GET /health``; the body is returned even on 503 (loading / no model)."""
        status, payload = self._request("GET", "/health")
        if not isinstance(payload, dict):
            raise InferenceBadReply(f"GET /health: expected a JSON object (HTTP {status})", status_code=503)
        return payload

    def get_props(self) -> dict[str, Any]:
        """``GET /props``: model alias/path, slot count, capabilities, ``n_ctx``/``n_embd``."""
        return self._call("GET", "/props")

    # ---- llama-server native inference -----------------------------------

    def completion(
        self,
        prompt: str,
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> dict[str, Any]:
        """``POST /completion`` (llama-server native shape; ``n_predict`` caps output)."""
        body: dict[str, Any] = {"prompt": prompt}
        if max_tokens is not None:
            body["n_predict"] = max_tokens
        if temperature is not None:
            body["temperature"] = temperature
        return self._call("POST", "/completion", body)

    def tokenize(self, content: str, *, with_pieces: bool = False) -> dict[str, Any]:
        """``POST /tokenize``; ``{"tokens": [...]}``, with ``{"id","piece"}`` items when ``with_pieces``."""
        return self._call("POST", "/tokenize", {"content": content, "with_pieces": with_pieces})

    def detokenize(self, tokens: Sequence[int]) -> str:
        """``POST /detokenize``; returns the decoded text."""
        payload = self._call("POST", "/detokenize", {"tokens": list(tokens)})
        return str(payload.get("content", ""))

    def rerank(self, query: str, documents: Sequence[str], *, top_n: int | None = None) -> dict[str, Any]:
        """``POST /v1/rerank``; 501 when the model is not a reranker."""
        body: dict[str, Any] = {"query": query, "documents": list(documents)}
        if top_n is not None:
            body["top_n"] = top_n
        return self._call("POST", "/v1/rerank", body)
