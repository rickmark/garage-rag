import ctypes.util
import os
from pathlib import Path

import pytest
from garage_rag import _libpq


def test_find_bundled_libpq_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    fake_libpq = tmp_path / "libpq.dylib"
    fake_libpq.write_text("")

    monkeypatch.setenv("GARAGE_LIBPQ_PATH", str(fake_libpq))
    assert _libpq.find_bundled_libpq() == str(fake_libpq)


def test_find_bundled_libpq_nested_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    postgres_dir = tmp_path / "postgres"
    postgres_dir.mkdir()
    lib_dir = postgres_dir / "lib"
    lib_dir.mkdir()
    fake_libpq = lib_dir / "libpq.dylib"
    fake_libpq.write_text("")

    monkeypatch.setenv("GARAGE_LIBPQ_PATH", str(postgres_dir))
    assert _libpq.find_bundled_libpq() == str(fake_libpq)


def test_configure_libpq_patches_find_library(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    fake_libpq = tmp_path / "libpq.dylib"
    fake_libpq.write_text("")

    monkeypatch.setenv("GARAGE_LIBPQ_PATH", str(fake_libpq))
    configured = _libpq.configure_libpq()
    assert configured == str(fake_libpq)

    assert ctypes.util.find_library("libpq") == str(fake_libpq)
    assert ctypes.util.find_library("libpq.dylib") == str(fake_libpq)
    assert ctypes.util.find_library("pq") == str(fake_libpq)


def test_configure_libpq_patches_psycopg(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    fake_libpq = tmp_path / "libpq.dylib"
    fake_libpq.write_text("")

    monkeypatch.setenv("GARAGE_LIBPQ_PATH", str(fake_libpq))
    _libpq.configure_libpq()

    import psycopg.pq.misc as pq_misc

    assert pq_misc.find_libpq_full_path() == str(fake_libpq)
