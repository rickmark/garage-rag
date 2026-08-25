"""Embedding via a local LM Studio server.

LM Studio exposes an OpenAI-compatible ``/v1/embeddings`` endpoint, so the
standard ``openai`` Python SDK works out of the box -- just point ``base_url``
at the local server.  No API key is needed for a local instance; the SDK
requires *something* in the field, so a placeholder is used.

Like Ollama, LM Studio serializes model execution on a single GPU, so batching
rather than fan-out is the right shape.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence

from openai import OpenAI

from garage_rag.config import get_settings

log = logging.getLogger(__name__)

# The OpenAI SDK requires a non-empty key even when the server ignores it.
_PLACEHOLDER_KEY = "lm-studio"


class EmbeddingError(RuntimeError):
    """The embedding backend could not produce vectors."""


class LMStudioEmbedder:
    """Batched embedding client targeting LM Studio's OpenAI-compatible API."""

    def __init__(self, model_ref: str, *, base_url: str | None = None) -> None:
        settings = get_settings()
        self.model_ref = model_ref
        self._client = OpenAI(
            base_url=base_url or settings.lmstudio_host,
            api_key=_PLACEHOLDER_KEY,
        )

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        """Embed a batch, preserving order."""
        if not texts:
            return []
        try:
            response = self._client.embeddings.create(
                model=self.model_ref,
                input=list(texts),
            )
        except Exception as exc:  # noqa: BLE001 - surface backend detail to caller
            raise EmbeddingError(f"lmstudio embed failed for {self.model_ref}: {exc}") from exc

        vectors = [item.embedding for item in response.data]
        if len(vectors) != len(texts):
            raise EmbeddingError(
                f"{self.model_ref} returned {len(vectors)} vectors for {len(texts)} inputs"
            )
        return vectors

    def probe_dims(self) -> int:
        """Actual output width, for verifying a registration."""
        return len(self.embed(["dimension probe"])[0])
