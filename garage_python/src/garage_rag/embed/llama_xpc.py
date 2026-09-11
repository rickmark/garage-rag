"""Llama XPC embedding provider.

Calls LlamaXPCService via LlamaXPCClient to generate embedding vectors.
"""

from __future__ import annotations

from collections.abc import Sequence

from garage_rag.embed.base import Embedder
from garage_rag.embed.ollama import EmbeddingError
from garage_rag.xpc.llama_xpc import LlamaXPCClient


class LlamaXPCEmbedder(Embedder):
    """Embedding backend backed by LlamaXPCService over macOS XPC."""

    def __init__(
        self,
        model_ref: str = "default",
        client: LlamaXPCClient | None = None,
    ) -> None:
        self.model_ref = model_ref
        self.client = client or LlamaXPCClient()

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        """Embed a batch of texts, preserving order."""
        if not texts:
            return []
        try:
            return self.client.embed_texts(texts, model=self.model_ref)
        except Exception as exc:
            raise EmbeddingError(f"llama_xpc embed failed for {self.model_ref}: {exc}") from exc

    def probe_dims(self) -> int:
        """Return the actual output width by embedding a short probe string."""
        vectors = self.embed(["probe"])
        if not vectors or not vectors[0]:
            raise ValueError(
                f"LlamaXPCEmbedder probe failed for model {self.model_ref!r}: received empty embedding response"
            )
        return len(vectors[0])
