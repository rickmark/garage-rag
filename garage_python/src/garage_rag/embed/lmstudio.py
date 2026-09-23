"""Embedding via an LM Studio server.

LM Studio exposes an OpenAI-compatible ``POST /v1/embeddings`` endpoint; one
JSON request per batch is all this needs, so it is made with the ``httpx``
client that :func:`garage_rag.net.egress.http_client` builds for
``embedding.lmstudio_host`` -- no SDK. Local instances need no API key;
authenticated instances can provide one through ``GARAGE_LMSTUDIO_API_TOKEN``
or the configured token file, sent as a bearer token.

Like Ollama, LM Studio serializes model execution on a single GPU, so batching
rather than fan-out is the right shape.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Sequence
from typing import Any

from garage_rag.config import get_settings
from garage_rag.embed.base import Embedder, EmbeddingError
from garage_rag.net import egress

log = logging.getLogger(__name__)

__all__ = ["EmbeddingError", "LMStudioEmbedder"]

# LM Studio loads a model on first use, which can take a while.
_TIMEOUT_SECONDS = 600.0
# Retried as the openai SDK this replaced retried them: twice, with a short backoff.
_MAX_RETRIES = 2
_RETRY_STATUSES = frozenset({408, 409, 429})


class LMStudioEmbedder(Embedder):
    """Batched embedding client targeting LM Studio's OpenAI-compatible API."""

    provider_name = "lmstudio"

    def __init__(
        self,
        model_ref: str,
        *,
        base_url: str | None = None,
        api_token: str | None = None,
    ) -> None:
        settings = get_settings()
        self.model_ref = model_ref
        token = api_token or settings.read_lmstudio_api_token()
        self._client = egress.http_client(
            purpose="embeddings:lmstudio",
            base_url=base_url or settings.lmstudio_host,
            timeout=_TIMEOUT_SECONDS,
            headers={"Authorization": f"Bearer {token}"} if token else None,
        )

    def _post(self, texts: list[str]) -> Any:
        for attempt in range(_MAX_RETRIES + 1):
            last = attempt == _MAX_RETRIES
            try:
                response = self._client.post("/embeddings", json={"model": self.model_ref, "input": texts})
            except egress.TransportError:
                if last:
                    raise
            else:
                if last or not (response.status_code in _RETRY_STATUSES or response.status_code >= 500):
                    return response
            time.sleep(0.5 * 2**attempt)
        raise AssertionError("unreachable")

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        response = self._post(texts)
        payload: Any
        try:
            payload = response.json()
        except ValueError:
            payload = None
        if response.status_code != 200:
            raise EmbeddingError(f"lmstudio embed failed for {self.model_ref}: {_error_message(payload, response)}")
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list):
            raise EmbeddingError(f"lmstudio embed failed for {self.model_ref}: reply has no 'data' list")
        rows: list[dict[str, Any]] = []
        for item in data:
            if not isinstance(item, dict):
                raise EmbeddingError(f"lmstudio embed failed for {self.model_ref}: malformed item {item!r}")
            rows.append(item)
        try:
            # The API numbers each vector with the index of its input; order by it.
            rows.sort(key=lambda row: row["index"])
            return [row["embedding"] for row in rows]
        except (KeyError, TypeError) as exc:
            raise EmbeddingError(f"lmstudio embed failed for {self.model_ref}: malformed item ({exc!r})") from exc


def _error_message(payload: Any, response: Any) -> str:
    """The server's own message for a failed request, else the HTTP status."""
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict) and error.get("message"):
            return f"HTTP {response.status_code}: {error['message']}"
        if isinstance(error, str) and error:
            return f"HTTP {response.status_code}: {error}"
    return f"HTTP {response.status_code}"
