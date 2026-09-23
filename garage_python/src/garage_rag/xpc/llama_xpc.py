"""HTTP client for the llama.cpp server hosted by the app's LlamaXPCService.

The Swift ``LlamaXPCService`` loads models over XPC (the app drives that) and
serves a llama-server / OpenAI-compatible HTTP API on loopback. This module is
the Python side: a small stdlib-only client (``urllib``, ``json``) that talks
to ``settings.llama_host`` (default :data:`DEFAULT_LLAMA_HTTP_URL`) and nothing
else.

The provider exists for on-device inference, so :class:`LlamaXPCClient`
refuses any base URL whose host is not loopback and never routes through an
HTTP proxy. That keeps the egress story simple: content handed to this client
cannot leave the machine, whatever the environment says.

Model load/unload are not HTTP operations; there is deliberately no
``load_model`` here.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from collections.abc import Sequence
from typing import Any, cast
from urllib.parse import urlsplit

from garage_rag.config import get_settings

logger = logging.getLogger(__name__)

__all__ = [
    "DEFAULT_LLAMA_HTTP_URL",
    "LlamaXPCClient",
    "LlamaXPCError",
    "is_loopback_url",
]

# Where LlamaXPCService binds its HTTP API; mirrored by ``Settings.llama_host``.
DEFAULT_LLAMA_HTTP_URL = "http://127.0.0.1:8790"

_LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})


def is_loopback_url(url: str) -> bool:
    """Whether ``url`` points at this machine. A bare ``host:port`` counts as a URL."""
    if "://" not in url:
        url = f"http://{url}"
    host = (urlsplit(url).hostname or "").lower()
    return host in _LOOPBACK_HOSTS or host.startswith("127.")


class LlamaXPCError(RuntimeError):
    """The llama.cpp server refused, failed, or could not be reached.

    ``status_code`` is the HTTP status for a server-side failure; connection
    failures and non-JSON replies report 503 (the service is not usable).
    """

    def __init__(self, message: str, status_code: int = 500) -> None:
        super().__init__(message)
        self.status_code = status_code


def _error_message(payload: Any, status: int) -> str:
    """Pull the human-readable message out of a llama-server error body."""
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict) and error.get("message"):
            return str(error["message"])
        if isinstance(error, str) and error:
            return error
        if payload.get("status"):
            return str(payload["status"])
    return f"HTTP {status}"


class LlamaXPCClient:
    """Client for the llama-server-compatible HTTP API of LlamaXPCService.

    Every method maps to one route; the docstrings name it. Non-2xx replies
    raise :class:`LlamaXPCError` carrying the server's message and status,
    except :meth:`health`, which returns the body whatever the status so a
    caller can tell "no model loaded" from "unreachable".
    """

    def __init__(self, base_url: str | None = None, *, timeout: float = 600.0) -> None:
        if base_url is None:
            base_url = get_settings().llama_host
        base_url = base_url.rstrip("/")
        if not is_loopback_url(base_url):
            raise LlamaXPCError(
                f"llama_host must be a loopback URL (127.0.0.1, localhost or ::1); got {base_url!r}",
                status_code=400,
            )
        self.base_url = base_url
        self.timeout = timeout
        # No proxies, ever: the host is loopback, and honouring ``http_proxy``
        # would be the one way content could leave the machine.
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    # ---- transport -------------------------------------------------------

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> tuple[int, Any]:
        """Send one request and return ``(status, decoded JSON)``.

        Raises :class:`LlamaXPCError` only when the server cannot be reached
        or replies with something that is not JSON; HTTP error statuses are
        returned to the caller to interpret.
        """
        url = self.base_url + path
        data = None
        headers = {"Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                status = response.status
                raw = response.read()
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read()
        except (urllib.error.URLError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise LlamaXPCError(f"cannot reach LlamaXPCService at {self.base_url}: {reason}", status_code=503) from exc
        try:
            payload = json.loads(raw) if raw else {}
        except ValueError as exc:
            raise LlamaXPCError(f"non-JSON reply from {method} {path} (HTTP {status})", status_code=503) from exc
        return status, payload

    def _call(self, method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        status, payload = self._request(method, path, body)
        if not 200 <= status < 300:
            raise LlamaXPCError(f"{method} {path}: {_error_message(payload, status)}", status_code=status)
        if not isinstance(payload, dict):
            raise LlamaXPCError(f"{method} {path}: expected a JSON object, got {type(payload).__name__}")
        return payload

    # ---- status ----------------------------------------------------------

    def health(self) -> dict[str, Any]:
        """``GET /health``; the body is returned even on 503 (loading / no model)."""
        status, payload = self._request("GET", "/health")
        if not isinstance(payload, dict):
            raise LlamaXPCError(f"GET /health: expected a JSON object (HTTP {status})", status_code=503)
        return payload

    def get_props(self) -> dict[str, Any]:
        """``GET /props``: model alias/path, slot count, capabilities, ``n_ctx``/``n_embd``."""
        return self._call("GET", "/props")

    def list_models(self) -> dict[str, Any]:
        """``GET /v1/models``."""
        return self._call("GET", "/v1/models")

    # ---- inference -------------------------------------------------------

    def embed_texts(
        self,
        texts: Sequence[str],
        *,
        model: str | None = None,
        dimensions: int | None = None,
    ) -> list[list[float]]:
        """``POST /v1/embeddings``; one L2-normalised vector per text, in input order.

        ``dimensions`` asks the server to truncate (Matryoshka) and re-normalise.
        """
        inputs = list(texts)
        if not inputs:
            return []
        body: dict[str, Any] = {"input": inputs}
        if model:
            body["model"] = model
        if dimensions is not None:
            body["dimensions"] = dimensions
        payload = self._call("POST", "/v1/embeddings", body)
        data = payload.get("data")
        if not isinstance(data, list):
            raise LlamaXPCError("POST /v1/embeddings: reply has no 'data' list")
        # isinstance narrows to list[object]; the items are JSON objects, and a malformed
        # one surfaces as the KeyError/TypeError handled below.
        items = cast(list[dict[str, Any]], data)
        try:
            ordered = sorted(items, key=lambda item: int(item["index"]))
            return [[float(x) for x in item["embedding"]] for item in ordered]
        except (KeyError, TypeError, ValueError) as exc:
            raise LlamaXPCError(f"POST /v1/embeddings: malformed embedding item: {exc}") from exc

    def chat_completion(
        self,
        messages: Sequence[dict[str, str]],
        *,
        model: str | None = None,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> dict[str, Any]:
        """``POST /v1/chat/completions`` (OpenAI shape)."""
        body: dict[str, Any] = {"messages": list(messages)}
        if model:
            body["model"] = model
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        if temperature is not None:
            body["temperature"] = temperature
        return self._call("POST", "/v1/chat/completions", body)

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
        """``POST /v1/rerank``; 501 (as :class:`LlamaXPCError`) when the model is not a reranker."""
        body: dict[str, Any] = {"query": query, "documents": list(documents)}
        if top_n is not None:
            body["top_n"] = top_n
        return self._call("POST", "/v1/rerank", body)
