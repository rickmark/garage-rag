"""HTTP client for the llama.cpp server hosted by the app's LlamaXPCService.

The Swift ``LlamaXPCService`` loads models over XPC (the app drives that) and
serves a llama-server / OpenAI-compatible HTTP API on loopback, at
``settings.llama_host`` (default :data:`DEFAULT_LLAMA_HTTP_URL`).

Embeddings, chat and the model list are the shared OpenAI-shaped routes of
:class:`garage_rag.inference.InferenceClient`; :class:`LlamaXPCClient` adds
the llama-server-only routes (health, props, raw completion, tokenizer,
rerank). The transport refuses any non-loopback ``llama_host`` and never uses
an HTTP proxy, so content handed to this client cannot leave the machine.

Model load/unload are not HTTP operations here; they go over NSXPC; the
inherited LM Studio management methods raise
:class:`~garage_rag.inference.InferenceUnsupported` here. When an embedding or
chat request finds its model not loaded, the client has it loaded on demand
through :func:`garage_rag.xpc.host.ensure_model` (the Swift host's NSXPC
loader, or the app over gRPC) and retries once; when that is impossible the
error says how to fix it.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from garage_rag.config import get_settings
from garage_rag.inference.client import (
    Backend,
    BackendKind,
    ChatResult,
    InferenceBadReply,
    InferenceClient,
    InferenceError,
    InferenceHTTPError,
    is_loopback_url,
)
from garage_rag.xpc.host import ModelLoadError, ensure_model

log = logging.getLogger(__name__)

__all__ = [
    "DEFAULT_LLAMA_HTTP_URL",
    "LlamaXPCClient",
    "LlamaXPCError",
    "is_loopback_url",
    "is_model_not_loaded",
]

# Where LlamaXPCService binds its HTTP API; mirrored by ``Settings.llama_host``.
DEFAULT_LLAMA_HTTP_URL = "http://127.0.0.1:8790"

# Kept for callers that catch the old name; every client error is an InferenceError.
LlamaXPCError = InferenceError


def is_model_not_loaded(exc: BaseException) -> bool:
    """Whether LlamaXPCService refused a request because its model is not resident.

    The engine answers 503 ``no model loaded`` when nothing is loaded and 404
    ``model X is not loaded (loaded: ...)`` when others are.
    """
    if not isinstance(exc, InferenceHTTPError) or exc.status_code not in (404, 503):
        return False
    text = str(exc).lower()
    return "no model loaded" in text or "is not loaded" in text


class LlamaXPCClient(InferenceClient):
    """:class:`InferenceClient` for LlamaXPCService, plus its llama-server-only routes."""

    def __init__(
        self,
        base_url: str | None = None,
        *,
        timeout: float = 600.0,
        ensure: Callable[[str], str] | None = None,
    ) -> None:
        """``ensure(model)`` loads a missing model (default :func:`garage_rag.xpc.host.ensure_model`)."""
        super().__init__(Backend(BackendKind.LLAMA_XPC, base_url or get_settings().llama_host, timeout=timeout))
        self._ensure = ensure

    # ---- on-demand loading ---------------------------------------------

    def _with_model_loaded[T](self, model: str | None, call: Callable[[], T]) -> T:
        """``call()``; if its model is not loaded, have it loaded and call once more."""
        try:
            return call()
        except InferenceHTTPError as exc:
            if not model or not is_model_not_loaded(exc):
                raise
            try:
                detail = (self._ensure or ensure_model)(model)
            except ModelLoadError as load_exc:
                raise InferenceHTTPError(
                    f"{exc}; loading it on demand failed: {load_exc}",
                    status_code=exc.status_code,
                    error_type=exc.error_type,
                ) from load_exc
            log.info("llama_xpc model %s loaded on demand: %s", model, detail)
            return call()

    def embed(self, texts: Sequence[str], model: str | None = None) -> list[list[float]]:
        """``POST /v1/embeddings``, loading ``model`` first if LlamaXPCService does not have it."""
        return self._with_model_loaded(model, lambda: InferenceClient.embed(self, texts, model))

    def chat(
        self,
        messages: Sequence[Mapping[str, Any]],
        model: str | None = None,
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
        response_format: Mapping[str, Any] | None = None,
    ) -> ChatResult:
        """``POST /v1/chat/completions``, loading ``model`` first if LlamaXPCService does not have it."""
        return self._with_model_loaded(
            model,
            lambda: InferenceClient.chat(
                self,
                messages,
                model,
                max_tokens=max_tokens,
                temperature=temperature,
                response_format=response_format,
            ),
        )

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
