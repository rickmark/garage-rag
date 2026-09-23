"""Local text generation for the ``rag_ask`` / ``rag_generate`` MCP tools and ``garage ask``.

:class:`LocalChatModel` is a small provider-neutral chat client built from the
``facts`` section of the configuration (``facts.provider`` / ``facts.model``).
Both providers are **local inference servers on this machine**; there is no
cloud path here at all (``test_egress_block`` fails the build if any module
imports a cloud AI SDK):

* ``llama_xpc`` -- the llama.cpp HTTP API the app's ``LlamaXPCService`` serves
  on ``embedding.llama_host`` (default ``http://127.0.0.1:8790``). The engine
  holds several models at once and picks one by the ``model`` alias in each
  request, so every call names ``facts.model``. :class:`LlamaXPCClient`
  refuses any non-loopback host and never uses an HTTP proxy.
* ``ollama`` -- a local Ollama server on ``embedding.ollama_host`` (default
  ``http://localhost:11434``), through the ``ollama`` SDK, the same client
  ``embed.ollama`` uses for embeddings.

Retrieved chunks -- communications included -- may be placed in a prompt to
either server; that is local inference on the owner's own machine, the same
as embedding them. Both hosts must be loopback: the configuration refuses any
other value, and :class:`LocalChatModel` checks again on construction.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import ollama

from garage_rag.config import Settings, get_settings, require_loopback
from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError

log = logging.getLogger(__name__)

__all__ = [
    "PROVIDERS",
    "ChatReply",
    "LocalChatModel",
    "LocalModelUnavailable",
]

PROVIDERS = ("llama_xpc", "ollama")

_PROVIDER_LABEL = {
    "llama_xpc": "the app's LlamaXPCService",
    "ollama": "the local Ollama server",
}


class LocalModelUnavailable(RuntimeError):
    """The configured local model could not answer.

    The message names the provider, host and model that were tried and how to
    fix it, because from an MCP client the only thing the person sees is this
    string.
    """


@dataclass
class ChatReply:
    """One completion plus whatever token accounting the server reported."""

    text: str
    prompt_tokens: int | None = None
    completion_tokens: int | None = None


class LocalChatModel:
    """Chat completions against the configured local model.

    ``provider`` and ``model_ref`` default to ``facts.provider`` and
    ``facts.model``; ``host`` is the matching ``embedding.*_host`` setting.
    Construction is cheap and makes no network call; :meth:`is_available`
    probes the server, :meth:`chat` runs a completion.
    """

    def __init__(
        self,
        *,
        provider: str | None = None,
        model_ref: str | None = None,
        settings: Settings | None = None,
    ) -> None:
        settings = settings or get_settings()
        self.provider = provider or settings.fact_provider
        if self.provider not in PROVIDERS:
            raise ValueError(f"unknown generation provider {self.provider!r}; expected one of {PROVIDERS}")
        self.model_ref = model_ref or settings.fact_model
        setting = "embedding.llama_host" if self.provider == "llama_xpc" else "embedding.ollama_host"
        self.host = require_loopback(
            settings.llama_host if self.provider == "llama_xpc" else settings.ollama_host, setting
        )
        self._llama: LlamaXPCClient | None = None
        self._ollama: ollama.Client | None = None

    # ---- description ----------------------------------------------------

    def describe(self) -> str:
        return f"{self.provider}/{self.model_ref} at {self.host}"

    def _unavailable(self, reason: str) -> LocalModelUnavailable:
        hint = (
            "load it on the app's Models page (Fact distillation)"
            if self.provider == "llama_xpc"
            else f"pull it with 'ollama pull {self.model_ref}'"
        )
        return LocalModelUnavailable(
            f"local model {self.model_ref!r} is not available from {_PROVIDER_LABEL[self.provider]} "
            f"({self.provider} at {self.host}): {reason}. "
            f"Check the model name in facts.model and {hint}; or switch facts.provider."
        )

    # ---- clients --------------------------------------------------------

    def _llama_client(self) -> LlamaXPCClient:
        if self._llama is None:
            self._llama = LlamaXPCClient(self.host)
        return self._llama

    def _ollama_client(self) -> ollama.Client:
        if self._ollama is None:
            self._ollama = ollama.Client(host=self.host, trust_env=False, follow_redirects=False)
        return self._ollama

    # ---- probing --------------------------------------------------------

    def is_available(self) -> bool:
        """Whether the server is up and serves ``model_ref``. Never raises."""
        try:
            if self.provider == "llama_xpc":
                client = self._llama_client()
                if str(client.health().get("status", "")).lower() != "ok":
                    return False
                served = _served_aliases(client.list_models())
                # An engine that does not enumerate its models cannot be
                # checked further; the request itself decides then.
                return not served or self.model_ref in served
            self._ollama_client().show(self.model_ref)
            return True
        except Exception as exc:  # any transport, HTTP or SDK failure means "no"
            log.debug("%s unavailable: %s", self.describe(), exc)
            return False

    # ---- generation -----------------------------------------------------

    def complete(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> ChatReply:
        """Run one chat completion; ``messages`` are OpenAI-style role/content dicts."""
        if self.provider == "llama_xpc":
            return self._complete_llama(messages, max_tokens=max_tokens, temperature=temperature)
        return self._complete_ollama(messages, max_tokens=max_tokens, temperature=temperature)

    def chat(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str:
        """:meth:`complete`, returning only the reply text."""
        return self.complete(messages, max_tokens=max_tokens, temperature=temperature).text

    def _complete_llama(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int | None,
        temperature: float | None,
    ) -> ChatReply:
        try:
            payload = self._llama_client().chat_completion(
                list(messages),
                model=self.model_ref,
                max_tokens=max_tokens,
                temperature=temperature,
            )
        except LlamaXPCError as exc:
            raise self._unavailable(str(exc)) from exc
        try:
            text = str(payload["choices"][0]["message"]["content"] or "")
        except (KeyError, IndexError, TypeError) as exc:
            raise self._unavailable(f"malformed chat reply ({exc!r})") from exc
        usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
        return ChatReply(
            text=text.strip(),
            prompt_tokens=_int_or_none(usage.get("prompt_tokens")),
            completion_tokens=_int_or_none(usage.get("completion_tokens")),
        )

    def _complete_ollama(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int | None,
        temperature: float | None,
    ) -> ChatReply:
        options: dict[str, Any] = {}
        if max_tokens is not None:
            options["num_predict"] = max_tokens
        if temperature is not None:
            options["temperature"] = temperature
        try:
            response = self._ollama_client().chat(
                model=self.model_ref,
                messages=list(messages),
                options=options or None,
            )
        except Exception as exc:  # ollama.ResponseError, httpx connection errors, ...
            raise self._unavailable(str(exc)) from exc
        message = getattr(response, "message", None) or {}
        content = getattr(message, "content", None)
        if content is None and isinstance(message, dict):
            content = message.get("content")
        return ChatReply(
            text=str(content or "").strip(),
            prompt_tokens=_int_or_none(getattr(response, "prompt_eval_count", None)),
            completion_tokens=_int_or_none(getattr(response, "eval_count", None)),
        )


def _served_aliases(payload: Any) -> set[str]:
    """Model ids out of a ``GET /v1/models`` reply, or empty when it has none."""
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        return set()
    return {str(item["id"]) for item in data if isinstance(item, dict) and item.get("id")}


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None
