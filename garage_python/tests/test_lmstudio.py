from __future__ import annotations

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.embed.lmstudio import LMStudioEmbedder


def test_uses_configured_lmstudio_token(monkeypatch) -> None:
    captured: dict[str, str] = {}

    class Client:
        def __init__(self, *, base_url: str, api_key: str) -> None:
            captured["base_url"] = base_url
            captured["api_key"] = api_key

    monkeypatch.setattr("garage_rag.embed.lmstudio.OpenAI", Client)
    set_settings(Settings(lmstudio_host="http://lm-studio.example/v1"))
    try:
        LMStudioEmbedder("text-embedding", api_token="lm-token")
    finally:
        reset_settings()

    assert captured == {
        "base_url": "http://lm-studio.example/v1",
        "api_key": "lm-token",
    }


def test_uses_placeholder_without_lmstudio_token(monkeypatch) -> None:
    captured: dict[str, str] = {}

    class Client:
        def __init__(self, *, base_url: str, api_key: str) -> None:
            captured["api_key"] = api_key

    monkeypatch.setattr("garage_rag.embed.lmstudio.OpenAI", Client)
    set_settings(Settings())
    try:
        LMStudioEmbedder("text-embedding")
    finally:
        reset_settings()

    assert captured["api_key"] == "lm-studio"
