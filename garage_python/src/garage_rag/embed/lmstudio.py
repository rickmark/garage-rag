"""Embedding via a local LM Studio server.

Posts to LM Studio's OpenAI-compatible ``/v1/embeddings`` through
:class:`garage_rag.inference.InferenceClient`. Local instances need no API
key; authenticated instances can provide one through
``GARAGE_LMSTUDIO_API_TOKEN`` or the configured token file, sent as a bearer
token.

LM Studio ignores ``dimensions``, so none is sent; vectors come back at the
model's full width and Garage truncates them itself where the storage plan
says so.

Like Ollama, LM Studio serializes model execution on a single GPU, so batching
rather than fan-out is the right shape.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import replace

from garage_rag.embed.base import Embedder, EmbeddingError
from garage_rag.inference import Backend, BackendKind, InferenceClient

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
        client: InferenceClient | None = None,
    ) -> None:
        self.model_ref = model_ref
        # Two retries on no reply or HTTP 408/409/429/5xx, as the openai SDK this replaced made.
        backend = replace(
            Backend.from_settings(BackendKind.LMSTUDIO, base_url=base_url, token=api_token), max_retries=2
        )
        self.client = client or InferenceClient(backend)

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        return self.client.embed(texts, self.model_ref)
