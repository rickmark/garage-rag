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

    original = getattr(ctypes.util, "_garage_original_find_library", ctypes.util.find_library)

    def find_library(name: str, _original=original, _path=path):  # type: ignore[no-untyped-def]
        if name in _LIBPQ_NAMES:
            return _path
        return _original(name)

    ctypes.util._garage_original_find_library = original  # type: ignore[attr-defined]
    ctypes.util._garage_libpq_path = path  # type: ignore[attr-defined]
    ctypes.util.find_library = find_library
    return path
