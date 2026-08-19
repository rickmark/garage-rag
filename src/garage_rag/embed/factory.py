"""Provider-agnostic embedder construction.

Call :func:`get_embedder` with a provider name and model reference to get the
right backend without the caller knowing which SDK is behind it.
"""

from __future__ import annotations

from .base import Embedder
from .lmstudio import LMStudioEmbedder
from .ollama import OllamaEmbedder

# Providers recognised by the factory. Extend this when a new backend is added.
PROVIDERS: set[str] = {"ollama", "lmstudio"}


def get_embedder(provider: str, model_ref: str) -> Embedder:
    """Construct the embedder for *provider* and *model_ref*.

    Raises ``ValueError`` for an unknown provider so registration catches
    typos immediately instead of failing at embed time.
    """
    if provider == "ollama":
        return OllamaEmbedder(model_ref)
    if provider == "lmstudio":
        return LMStudioEmbedder(model_ref)
    raise ValueError(
        f"unknown embedding provider {provider!r}; supported: {', '.join(sorted(PROVIDERS))}"
    )
