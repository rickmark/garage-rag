"""``LocalChatModel``: one chat client, two local backends, no cloud path."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import Settings
from garage_rag.enrich.generation import ChatReply, LocalChatModel, LocalModelUnavailable
from garage_rag.xpc.llama_xpc import LlamaXPCError

MESSAGES = [{"role": "system", "content": "be brief"}, {"role": "user", "content": "hi"}]


def _llama_model(**overrides) -> LocalChatModel:
    return LocalChatModel(settings=Settings(**overrides))


class TestConstruction:
    def test_defaults_come_from_the_facts_section(self) -> None:
        model = _llama_model()
        assert model.provider == "llama_xpc"
        assert model.model_ref == "gemma2-2b"
        assert model.host == "http://127.0.0.1:8790"
        assert model.is_local

    def test_ollama_uses_the_ollama_host(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", fact_model="gemma2:2b"))
        assert model.provider == "ollama"
        assert model.host == "http://localhost:11434"
        assert model.is_local

    def test_explicit_arguments_win(self) -> None:
        model = LocalChatModel(provider="ollama", model_ref="phi", settings=Settings())
        assert (model.provider, model.model_ref) == ("ollama", "phi")

    def test_unknown_provider_is_rejected(self) -> None:
        with pytest.raises(ValueError, match="unknown generation provider"):
            LocalChatModel(provider="openai", settings=Settings())

    def test_non_loopback_ollama_is_not_local(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", ollama_host="http://gpu-box:11434"))
        assert not model.is_local


class TestLlamaXPC:
    def test_chat_sends_the_model_alias_and_returns_text(self) -> None:
        model = _llama_model(fact_model="gemma2-2b")
        client = MagicMock()
        client.chat_completion.return_value = {
            "choices": [{"message": {"role": "assistant", "content": "  hello  "}}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 3},
        }
        with patch.object(model, "_llama_client", return_value=client):
            reply = model.complete(MESSAGES, max_tokens=64, temperature=0.2)
        assert reply == ChatReply(text="hello", prompt_tokens=12, completion_tokens=3)
        client.chat_completion.assert_called_once_with(MESSAGES, model="gemma2-2b", max_tokens=64, temperature=0.2)

    def test_chat_is_the_text_only_view(self) -> None:
        model = _llama_model()
        client = MagicMock()
        client.chat_completion.return_value = {"choices": [{"message": {"content": "x"}}]}
        with patch.object(model, "_llama_client", return_value=client):
            assert model.chat(MESSAGES) == "x"

    def test_request_body_names_the_model(self) -> None:
        """End to end through the real client: the wire body carries ``model``."""
        from garage_rag.xpc.llama_xpc import LlamaXPCClient

        model = _llama_model(fact_model="gemma2-2b")
        captured: dict = {}

        def fake_call(self, method, path, body=None):
            captured.update(method=method, path=path, body=body)
            return {"choices": [{"message": {"content": "ok"}}]}

        with patch.object(LlamaXPCClient, "_call", fake_call):
            model.chat([{"role": "user", "content": "hi"}], max_tokens=8)
        assert captured["method"] == "POST"
        assert captured["path"] == "/v1/chat/completions"
        assert captured["body"] == {
            "messages": [{"role": "user", "content": "hi"}],
            "model": "gemma2-2b",
            "max_tokens": 8,
        }

    def test_transport_failure_becomes_a_clear_error(self) -> None:
        model = _llama_model()
        client = MagicMock()
        client.chat_completion.side_effect = LlamaXPCError("cannot reach LlamaXPCService at http://127.0.0.1:8790")
        with patch.object(model, "_llama_client", return_value=client), pytest.raises(LocalModelUnavailable) as info:
            model.chat(MESSAGES)
        message = str(info.value)
        assert "llama_xpc" in message
        assert "http://127.0.0.1:8790" in message
        assert "gemma2-2b" in message
        assert "Models page" in message

    def test_is_available_checks_health_and_the_served_aliases(self) -> None:
        model = _llama_model(fact_model="gemma2-2b")
        client = MagicMock()
        client.health.return_value = {"status": "ok"}
        client.list_models.return_value = {"data": [{"id": "bge-m3"}, {"id": "gemma2-2b"}]}
        with patch.object(model, "_llama_client", return_value=client):
            assert model.is_available()
        client.list_models.return_value = {"data": [{"id": "bge-m3"}]}
        with patch.object(model, "_llama_client", return_value=client):
            assert not model.is_available()
        client.health.return_value = {"error": {"message": "Loading model"}}
        with patch.object(model, "_llama_client", return_value=client):
            assert not model.is_available()

    def test_is_available_is_false_when_unreachable(self) -> None:
        model = _llama_model()
        client = MagicMock()
        client.health.side_effect = LlamaXPCError("nope", status_code=503)
        with patch.object(model, "_llama_client", return_value=client):
            assert model.is_available() is False


class TestOllama:
    def test_chat_maps_options_and_usage(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", fact_model="gemma2:2b"))
        client = MagicMock()
        client.chat.return_value = MagicMock(message=MagicMock(content="hi there"), prompt_eval_count=20, eval_count=4)
        with patch.object(model, "_ollama_client", return_value=client):
            reply = model.complete(MESSAGES, max_tokens=32, temperature=0.5)
        assert reply == ChatReply(text="hi there", prompt_tokens=20, completion_tokens=4)
        client.chat.assert_called_once_with(
            model="gemma2:2b", messages=MESSAGES, options={"num_predict": 32, "temperature": 0.5}
        )

    def test_failure_names_the_ollama_host(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", fact_model="gemma2:2b"))
        client = MagicMock()
        client.chat.side_effect = ConnectionError("refused")
        with patch.object(model, "_ollama_client", return_value=client), pytest.raises(LocalModelUnavailable) as info:
            model.chat(MESSAGES)
        assert "ollama" in str(info.value)
        assert "http://localhost:11434" in str(info.value)
        assert "ollama pull gemma2:2b" in str(info.value)

    def test_is_available_uses_show(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", fact_model="gemma2:2b"))
        client = MagicMock()
        with patch.object(model, "_ollama_client", return_value=client):
            assert model.is_available()
        client.show.assert_called_once_with("gemma2:2b")
        client.show.side_effect = RuntimeError("model not found")
        with patch.object(model, "_ollama_client", return_value=client):
            assert not model.is_available()
