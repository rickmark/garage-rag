"""LangExtract provider that runs fact-distillation prompts on a local inference server.

Every backend Garage uses -- the app's LlamaXPCService, Ollama and LM Studio --
speaks the OpenAI-compatible ``/v1/chat/completions`` route, so one provider
serves all three: :class:`LocalLanguageModel` posts each prompt through a
:class:`garage_rag.inference.InferenceClient`. Everything else (prompting,
few-shot examples, JSON parsing, grounding) is the vendored LangExtract's
(:mod:`garage_rag.enrich.langextract`); only the transport is ours, the same
loopback-only client embeddings and generation use.

``response_format``, ``temperature`` and an optional system prompt are
per-instance so each backend keeps the request settings it had before (see
``enrich.facts.facts_language_model``); note that LM Studio rejects
``{"type": "json_object"}`` with HTTP 400.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator, Mapping, Sequence
from typing import Any

from garage_rag.enrich.langextract import base_model, exceptions, schema
from garage_rag.enrich.langextract import types as core_types
from garage_rag.inference import InferenceClient, InferenceError


@dataclasses.dataclass(init=False)
class LocalLanguageModel(base_model.BaseLanguageModel):
    """Runs LangExtract prompts through a local server's ``/v1/chat/completions``."""

    model_id: str
    format_type: core_types.FormatType = core_types.FormatType.JSON
    _client: Any = dataclasses.field(default=None, repr=False, compare=False)
    _temperature: float | None = dataclasses.field(default=None, repr=False, compare=False)
    _response_format: Mapping[str, Any] | None = dataclasses.field(default=None, repr=False, compare=False)
    _system_prompt: str | None = dataclasses.field(default=None, repr=False, compare=False)

    @classmethod
    def get_schema_class(cls) -> type[schema.BaseSchema] | None:
        return schema.FormatModeSchema

    def __init__(
        self,
        model_id: str,
        client: InferenceClient,
        *,
        temperature: float | None = None,
        response_format: Mapping[str, Any] | None = None,
        system_prompt: str | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(constraint=schema.Constraint())
        self.model_id = model_id
        self.format_type = core_types.FormatType.JSON
        # ``kwargs`` absorbs the provider-generic options LangExtract may pass
        # (max_workers, ...); none of them apply to this transport.
        self._client = client
        self._temperature = temperature
        self._response_format = response_format
        self._system_prompt = system_prompt

    @property
    def client(self) -> InferenceClient:
        return self._client

    def infer(self, batch_prompts: Sequence[str], **kwargs: Any) -> Iterator[Sequence[core_types.ScoredOutput]]:
        system = [{"role": "system", "content": self._system_prompt}] if self._system_prompt else []
        for prompt in batch_prompts:
            try:
                result = self._client.chat(
                    [*system, {"role": "user", "content": prompt}],
                    self.model_id,
                    temperature=self._temperature,
                    response_format=self._response_format,
                )
            except InferenceError as exc:
                label = self._client.backend.label
                raise exceptions.InferenceRuntimeError(
                    f"{label} inference failed: {exc}", original=exc, provider=label
                ) from exc
            yield [core_types.ScoredOutput(score=1.0, output=result.text)]
