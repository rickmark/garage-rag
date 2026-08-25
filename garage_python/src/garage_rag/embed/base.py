"""Embedding provider protocol.

Every provider implements the same two-method interface so the rest of the
pipeline -- backfill, search, dimension verification -- stays provider-agnostic.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Protocol, runtime_checkable


@runtime_checkable
class Embedder(Protocol):
    """Minimal contract every embedding backend must satisfy."""

    model_ref: str

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        """Embed a batch of texts, preserving order."""
        ...

    def probe_dims(self) -> int:
        """Return the actual output width by embedding a short probe string."""
        ...
