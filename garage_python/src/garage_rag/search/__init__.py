"""Search over the corpus.

Only the lightweight shared types live here; :mod:`garage_rag.search.hybrid`
imports every embedding backend and is loaded on demand.
"""

from typing import Literal

SearchMode = Literal["hybrid", "vector", "fts"]

__all__ = ["SearchMode"]
