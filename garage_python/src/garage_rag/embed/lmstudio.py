"""Embedding via a local LM Studio server.

LM Studio exposes an OpenAI-compatible ``/v1/embeddings`` endpoint, so the
standard ``openai`` Python SDK works out of the box -- just point ``base_url``
at the local server. Local instances need no API key; authenticated instances
can provide one through ``GARAGE_LMSTUDIO_API_TOKEN`` or the configured token
file. The SDK requires a non-empty key, so unauthenticated requests use a
placeholder.

Like Ollama, LM Studio serializes model execution on a single GPU, so batching
rather than fan-out is the right shape.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence

from openai import OpenAI

from garage_rag.config import get_settings
from garage_rag.embed.base import Embedder, EmbeddingError

log = logging.getLogger(__name__)

# The OpenAI SDK requires a non-empty key even when the server ignores it.
_PLACEHOLDER_KEY = "lm-studio"

__all__ = ["EmbeddingError", "LMStudioEmbedder"]


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
        self._client = OpenAI(
            base_url=base_url or settings.lmstudio_host,
            api_key=api_token or settings.read_lmstudio_api_token() or _PLACEHOLDER_KEY,
        )

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        response = self._client.embeddings.create(model=self.model_ref, input=texts)
        return [item.embedding for item in response.data]
