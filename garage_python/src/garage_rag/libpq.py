"""Point psycopg at the libpq shipped inside the Garage application bundle.

psycopg's pure Python implementation locates libpq via ``ctypes.util.find_library``
and falls back to ``pg_config --libdir``. Inside a hardened-runtime process that
resolves to a Homebrew/system copy signed by a different Team ID, which dyld
rejects ("mapping process and mapped file (non-platform) have different Team IDs").

The Swift host (``GaragePythonRuntime``) dlopens the bundled ``libpq.dylib`` and
exports its path through ``GARAGE_LIBPQ_PATH``; this module makes psycopg use it.
It must run before ``psycopg`` is imported (``garage_rag/__init__.py`` calls it).
"""

from __future__ import annotations

import ctypes.util
import os
from collections.abc import Callable

ENV_VAR = "GARAGE_LIBPQ_PATH"
_LIBPQ_NAMES = frozenset({"pq", "libpq", "libpq.dylib", "libpq.5.dylib", "libpq.5"})


def bundled_libpq_path() -> str | None:
    """Return the libpq path configured by the host, if it exists on disk."""
    path = os.environ.get(ENV_VAR)
    if path and os.path.isfile(path):
        return path
    return None


def configure() -> str | None:
    """Install a ``ctypes.util.find_library`` shim that resolves libpq to the bundled copy.

    Idempotent; returns the path that psycopg will use (or ``None`` when not configured).
    """
    path = bundled_libpq_path()
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
