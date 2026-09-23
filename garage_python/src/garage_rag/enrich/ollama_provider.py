"""LangExtract provider that runs fact-distillation prompts through a local Ollama server.

A small ``httpx`` replacement for upstream LangExtract's ``OllamaLanguageModel``,
which needed ``requests`` and sat behind a provider registry that also routes
to Google and OpenAI. The request is the same one upstream sends: ``POST
/api/generate`` with JSON mode, ``think`` off, temperature 0.1, a 2048-token
context and a five-minute ``keep_alive``; GPT-OSS models go through
``/api/chat`` with a JSON-only system instruction instead, because their
response format conflicts with Ollama's JSON mode.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator, Mapping, Sequence
from typing import Any

import httpx

from garage_rag.enrich.langextract import base_model, exceptions, schema
from garage_rag.enrich.langextract import types as core_types

DEFAULT_TEMPERATURE = 0.1
DEFAULT_TIMEOUT = 120.0
DEFAULT_KEEP_ALIVE = 5 * 60
DEFAULT_NUM_CTX = 2048

_GPT_OSS_JSON_SYSTEM_INSTRUCTION = (
    "Output a single JSON object matching the requested extraction format. "
    "Do not include code fences, prose, or reasoning."
)


def _is_gpt_oss_model(model_id: str) -> bool:
    normalized = model_id.lower()
    return normalized == "gpt-oss" or (normalized.startswith("gpt-oss:") and len(normalized) > len("gpt-oss:"))


@dataclasses.dataclass(init=False)
class OllamaLanguageModel(base_model.BaseLanguageModel):
    """Runs LangExtract prompts through Ollama's HTTP API."""

    model_id: str
    model_url: str
    format_type: core_types.FormatType = core_types.FormatType.JSON
    _client: Any = dataclasses.field(default=None, repr=False, compare=False)

    @classmethod
    def get_schema_class(cls) -> type[schema.BaseSchema] | None:
        return schema.FormatModeSchema

    def __init__(
        self,
        model_id: str,
        model_url: str,
        *,
        timeout: float = DEFAULT_TIMEOUT,
        client: httpx.Client | None = None,
    ) -> None:
        super().__init__(constraint=schema.Constraint())
        self.model_id = model_id
        self.model_url = model_url.rstrip("/")
        self.format_type = core_types.FormatType.JSON
        # No proxies: the environment's http_proxy must not decide where document text goes.
        self._client = client or httpx.Client(timeout=timeout, trust_env=False)

    def _options(self) -> dict[str, Any]:
        return {"keep_alive": DEFAULT_KEEP_ALIVE, "temperature": DEFAULT_TEMPERATURE, "num_ctx": DEFAULT_NUM_CTX}

    def _post(self, path: str, payload: Mapping[str, Any]) -> Mapping[str, Any]:
        try:
            response = self._client.post(
                f"{self.model_url}{path}", json=payload, headers={"Accept": "application/json"}
            )
        except httpx.TimeoutException as exc:
            raise exceptions.InferenceRuntimeError(
                f"Ollama model timed out ({exc})", original=exc, provider="Ollama"
            ) from exc
        except httpx.HTTPError as exc:
            raise exceptions.InferenceRuntimeError(
                f"Ollama request failed: {exc}", original=exc, provider="Ollama"
            ) from exc
        if response.status_code == 404:
            raise exceptions.InferenceConfigError(f"Can't find Ollama {self.model_id}. Try: ollama run {self.model_id}")
        if response.status_code != 200:
            raise exceptions.InferenceRuntimeError(
                f"Bad status code from Ollama: {response.status_code}", provider="Ollama"
            )
        return response.json()

    def _generate(self, prompt: str) -> str:
        response = self._post(
            "/api/generate",
            {
                "model": self.model_id,
                "prompt": prompt,
                "system": "",
                "stream": False,
                "raw": False,
                "options": self._options(),
                "keep_alive": DEFAULT_KEEP_ALIVE,
                "format": "json",
                "think": False,
            },
        )
        if output := response.get("response"):
            return output
        if response.get("thinking"):
            raise exceptions.InferenceRuntimeError(
                "Ollama returned an empty response with a thinking trace.", provider="Ollama"
            )
        raise exceptions.InferenceRuntimeError(
            "Ollama response did not include generated text in the 'response' field.", provider="Ollama"
        )

    def _chat(self, prompt: str) -> str:
        response = self._post(
            "/api/chat",
            {
                "model": self.model_id,
                "messages": [
                    {"role": "system", "content": _GPT_OSS_JSON_SYSTEM_INSTRUCTION},
                    {"role": "user", "content": prompt},
                ],
                "stream": False,
                "options": self._options(),
                "keep_alive": DEFAULT_KEEP_ALIVE,
                "think": False,
            },
        )
        message = response.get("message")
        if isinstance(message, Mapping) and (output := message.get("content")):
            return output
        raise exceptions.InferenceRuntimeError(
            "Ollama chat response did not include generated text in the 'message.content' field.", provider="Ollama"
        )

    def infer(self, batch_prompts: Sequence[str], **kwargs: Any) -> Iterator[Sequence[core_types.ScoredOutput]]:
        # ``kwargs`` carries LangExtract's pipeline options (max_workers, ...); none apply to this transport.
        query = self._chat if _is_gpt_oss_model(self.model_id) else self._generate
        for prompt in batch_prompts:
            yield [core_types.ScoredOutput(score=1.0, output=query(prompt))]
