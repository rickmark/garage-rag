"""Point psycopg at the libpq that PythonXPCService.framework loads.

psycopg's pure Python implementation locates libpq via ``ctypes.util.find_library``
and falls back to ``pg_config --libdir``. Inside a hardened-runtime process that
resolves to a Homebrew/system copy signed by a different Team ID, which dyld
rejects ("mapping process and mapped file (non-platform) have different Team IDs").

In the app, the framework links libpq, so it is already loaded when Python starts
(:func:`garage_rag.native.loaded_library`); this module makes psycopg use that copy.
It must run before ``psycopg`` is imported (``garage_rag/__init__.py`` calls it).
"""

from __future__ import annotations

import ctypes.util
from collections.abc import Callable

from garage_rag.native import loaded_library

_LIBPQ_NAMES = frozenset({"pq", "libpq", "libpq.dylib", "libpq.5.dylib", "libpq.5"})


def configure() -> str | None:
    """Install a ``ctypes.util.find_library`` shim that resolves libpq to the loaded copy.

    Idempotent; returns the path that psycopg will use (or ``None`` when no libpq is
    loaded, as in a plain venv, where psycopg's own search applies).
    """
    path = loaded_library("pq")
    if not path:
        return None
    if getattr(ctypes.util, "_garage_libpq_path", None) == path:
        return path

    original: Callable[[str], str | None] = getattr(
        ctypes.util, "_garage_original_find_library", ctypes.util.find_library
    )

    def find_library(name: str) -> str | None:
        if name in _LIBPQ_NAMES:
            return path
        return original(name)

    # Monkey-patching ctypes.util is the whole point of this module, so each of
    # these three writes is deliberate: two private stash slots this module
    # invents (read back by the getattr calls above) and the shim itself.
    ctypes.util._garage_original_find_library = original  # ty: ignore[unresolved-attribute]
    ctypes.util._garage_libpq_path = path  # ty: ignore[unresolved-attribute]
    ctypes.util.find_library = find_library  # ty: ignore[invalid-assignment]
    return path
