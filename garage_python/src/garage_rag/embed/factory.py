"""Provider-agnostic embedder construction.

Call :func:`get_embedder` with a provider name and model reference to get the
right backend without the caller knowing which SDK is behind it.

Backends are imported lazily: each one pulls in its own SDK (``ollama``,
``openai``, the XPC bridge), and a process that only ever talks to one of them
should not pay to import the others.
"""

from __future__ import annotations

from garage_rag.embed.base import Embedder

# Providers recognised by the factory. Extend this when a new backend is added.
PROVIDERS: set[str] = {"ollama", "lmstudio", "llama_xpc"}


def get_embedder(provider: str, model_ref: str) -> Embedder:
    """Construct the embedder for *provider* and *model_ref*.

    Raises ``ValueError`` for an unknown provider so registration catches
    typos immediately instead of failing at embed time.
    """
    if provider == "ollama":
        from garage_rag.embed.ollama import OllamaEmbedder

        return OllamaEmbedder(model_ref)
    if provider == "lmstudio":
        from garage_rag.embed.lmstudio import LMStudioEmbedder

        return LMStudioEmbedder(model_ref)
    if provider == "llama_xpc":
        from garage_rag.embed.llama_xpc import LlamaXPCEmbedder

        return LlamaXPCEmbedder(model_ref)
    raise ValueError(
        f"unknown embedding provider {provider!r}; supported: {', '.join(sorted(PROVIDERS))}"
    )
