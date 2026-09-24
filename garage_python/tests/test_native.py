"""garage_rag.native: finding a library among the images loaded into the process."""

from __future__ import annotations

import ctypes
import sys

import pytest

from garage_rag import libpq
from garage_rag.native import loaded_library

darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="dyld image list is macOS only")


@darwin_only
def test_finds_a_loaded_library_by_name():
    ctypes.CDLL("/usr/lib/libz.1.dylib")
    path = loaded_library("z")
    assert path is not None
    assert path.endswith("/libz.1.dylib")


def test_a_library_that_is_not_loaded_is_none():
    assert loaded_library("garage-no-such-library") is None


@pytest.mark.skipif(sys.platform == "darwin", reason="elsewhere there is no dyld image list")
def test_nothing_is_found_off_macos():
    assert loaded_library("c") is None


def test_psycopg_is_pointed_at_the_loaded_libpq(monkeypatch):
    monkeypatch.setattr(libpq, "loaded_library", lambda name: "/frameworks/libpq.dylib" if name == "pq" else None)
    monkeypatch.setattr(libpq.ctypes.util, "find_library", lambda name: f"/usr/lib/lib{name}.dylib")
    for slot in ("_garage_libpq_path", "_garage_original_find_library"):
        monkeypatch.delattr(libpq.ctypes.util, slot, raising=False)

    assert libpq.configure() == "/frameworks/libpq.dylib"
    assert libpq.ctypes.util.find_library("pq") == "/frameworks/libpq.dylib"
    assert libpq.ctypes.util.find_library("z") == "/usr/lib/libz.dylib"


def test_without_a_loaded_libpq_psycopg_searches_as_usual(monkeypatch):
    monkeypatch.setattr(libpq, "loaded_library", lambda name: None)
    assert libpq.configure() is None
