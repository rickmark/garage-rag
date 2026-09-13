"""Dynamic library resolver for libpq on macOS and other platforms.

Ensures that psycopg loads the bundled libpq.dylib (e.g. from
Contents/Resources/postgres/lib/libpq.dylib) rather than searching
untrusted or non-platform Homebrew paths that fail macOS code signing checks.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
from pathlib import Path
import sys

logger = logging.getLogger(__name__)

# Ensure psycopg uses the python implementation (ctypes + bundled libpq) on macOS
os.environ.setdefault("PSYCOPG_IMPL", "python")

_configured_libpq_path: str | None = None


def find_bundled_libpq() -> str | None:
    """Find the path to the bundled libpq.dylib library if present."""
    # 1. Explicit environment variable
    if env_path := os.environ.get("GARAGE_LIBPQ_PATH"):
        p = Path(env_path)
        if p.is_file():
            return str(p)
        if (p / "libpq.dylib").is_file():
            return str(p / "libpq.dylib")
        if (p / "libpq.5.dylib").is_file():
            return str(p / "libpq.5.dylib")
        if (p / "lib" / "libpq.dylib").is_file():
            return str(p / "lib" / "libpq.dylib")
        if (p / "lib" / "libpq.5.dylib").is_file():
            return str(p / "lib" / "libpq.5.dylib")

    # 2. Check candidate locations relative to executable, sys.prefix, and module location
    search_roots: list[Path] = []
    if sys.executable:
        search_roots.append(Path(sys.executable).resolve())
    if sys.prefix:
        search_roots.append(Path(sys.prefix).resolve())
    search_roots.append(Path(__file__).resolve())

    candidates: list[Path] = []
    for root in search_roots:
        for parent in [root] + list(root.parents):
            candidates.extend([
                parent / "Contents" / "Resources" / "postgres" / "lib" / "libpq.dylib",
                parent / "Contents" / "Resources" / "postgres" / "lib" / "libpq.5.dylib",
                parent / "Resources" / "postgres" / "lib" / "libpq.dylib",
                parent / "Resources" / "postgres" / "lib" / "libpq.5.dylib",
                parent / "postgres" / "lib" / "libpq.dylib",
                parent / "postgres" / "lib" / "libpq.5.dylib",
                parent / "ext" / "postgres" / "postgres_rpath" / "lib" / "libpq.dylib",
                parent / "bazel-bin" / "ext" / "postgres" / "postgres_rpath" / "lib" / "libpq.dylib",
            ])

    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)

    return None


def configure_libpq() -> str | None:
    """Dynamically configure and load the bundled libpq library using dyld/ctypes."""
    global _configured_libpq_path

    bundled = find_bundled_libpq()
    if not bundled:
        return None

    _configured_libpq_path = bundled
    os.environ["GARAGE_LIBPQ_PATH"] = bundled

    # Dynamically load via ctypes/dyld
    try:
        ctypes.cdll.LoadLibrary(bundled)
    except Exception as e:
        logger.debug("ctypes LoadLibrary on %s failed: %s", bundled, e)

    # Patch ctypes.util.find_library for libpq
    try:
        orig_find_library = ctypes.util.find_library

        def _custom_find_library(name: str) -> str | None:
            if name in ("libpq", "libpq.dylib", "libpq.5.dylib", "pq"):
                if os.path.isfile(bundled):
                    return bundled
            return orig_find_library(name)

        ctypes.util.find_library = _custom_find_library
    except Exception as e:
        logger.debug("Failed to patch ctypes.util.find_library: %s", e)

    # Patch psycopg.pq.misc.find_libpq_full_path if available or when imported
    try:
        import psycopg.pq.misc as pq_misc

        orig_find_libpq = getattr(pq_misc, "find_libpq_full_path", None)

        def _custom_find_libpq_full_path() -> str | None:
            if os.path.isfile(bundled):
                return bundled
            if orig_find_libpq:
                return orig_find_libpq()
            return None

        pq_misc.find_libpq_full_path = _custom_find_libpq_full_path
        if hasattr(pq_misc.find_libpq_full_path, "cache_clear"):
            pq_misc.find_libpq_full_path.cache_clear()
    except Exception as e:
        logger.debug("Failed to patch psycopg.pq.misc.find_libpq_full_path: %s", e)

    return bundled


# Automatically configure when module is imported
configure_libpq()
