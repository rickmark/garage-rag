from __future__ import annotations

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.embed.lmstudio import LMStudioEmbedder
from garage_rag.inference import BackendKind


@pytest.fixture(autouse=True)
def _no_env_token(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("GARAGE_LMSTUDIO_API_TOKEN", raising=False)


def test_uses_configured_lmstudio_host_and_explicit_token() -> None:
    set_settings(Settings(lmstudio_host="http://127.0.0.1:1300/v1"))
    try:
        embedder = LMStudioEmbedder("text-embedding", api_token="lm-token")
    finally:
        reset_settings()

    backend = embedder.client.backend
    assert backend.kind is BackendKind.LMSTUDIO
    # The server root: /v1 and /api/v1 routes are added per request.
    assert backend.base_url == "http://127.0.0.1:1300"
    assert backend.token == "lm-token"


def test_reads_the_token_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GARAGE_LMSTUDIO_API_TOKEN", "env-token")
    set_settings(Settings())
    try:
        embedder = LMStudioEmbedder("text-embedding")
    finally:
        reset_settings()
    assert embedder.client.backend.token == "env-token"


def test_no_token_without_one_configured() -> None:
    set_settings(Settings())
    try:
        embedder = LMStudioEmbedder("text-embedding")
    finally:
        reset_settings()
    assert embedder.client.backend.token is None
    assert embedder.client.base_url == "http://localhost:1234"


def test_keeps_the_two_retries_the_openai_sdk_made() -> None:
    set_settings(Settings())
    try:
        assert LMStudioEmbedder("text-embedding").client.backend.max_retries == 2
    finally:
        reset_settings()
