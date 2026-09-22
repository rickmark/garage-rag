"""Llama XPC embedding provider.

Calls LlamaXPCService via LlamaXPCClient to generate embedding vectors.
"""

from __future__ import annotations

from collections.abc import Sequence

from garage_rag.embed.base import Embedder, EmbeddingError
from garage_rag.xpc.llama_xpc import LlamaXPCClient

__all__ = ["EmbeddingError", "LlamaXPCEmbedder"]


class LlamaXPCEmbedder(Embedder):
    """Embedding backend backed by LlamaXPCService over macOS XPC."""

    provider_name = "llama_xpc"

    def __init__(
        self,
        model_ref: str = "default",
        client: LlamaXPCClient | None = None,
    ) -> None:
        self.model_ref = model_ref
        self.client = client or LlamaXPCClient()

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        return self.client.embed_texts(texts, model=self.model_ref)
