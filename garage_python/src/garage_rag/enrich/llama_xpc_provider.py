"""LangExtract provider that runs fact-distillation prompts through LlamaXPC.

`LlamaXPCClient` (`garage_rag.xpc.llama_xpc`) is an in-process bridge to the
LlamaXPCService's llama-server -- not a listening HTTP endpoint -- so this
provider calls it directly rather than posting to a `base_url` like
LangExtract's built-in Ollama/OpenAI providers do. Everything else (prompting,
few-shot examples, JSON parsing, grounding) is still LangExtract's; only the
transport is swapped, so nothing here needs to change once the LlamaXPC
backend grows a real inference engine behind the same client interface.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator, Sequence
from typing import Any

from langextract.core import base_model, schema
from langextract.core import types as core_types

from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError


@dataclasses.dataclass(init=False)
class LlamaXPCLanguageModel(base_model.BaseLanguageModel):
    """Runs LangExtract prompts through the local LlamaXPCService, in-process."""

    model_id: str
    format_type: core_types.FormatType = core_types.FormatType.JSON
    _client: Any = dataclasses.field(default=None, repr=False, compare=False)

    @classmethod
    def get_schema_class(cls) -> type[schema.BaseSchema] | None:
        return schema.FormatModeSchema

    def __init__(
        self,
        model_id: str,
        client: LlamaXPCClient | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(constraint=schema.Constraint())
        self.model_id = model_id
        self.format_type = core_types.FormatType.JSON
        self._client = client or LlamaXPCClient()
        self._extra_kwargs = kwargs or {}

    def infer(
        self, batch_prompts: Sequence[str], **kwargs: Any
    ) -> Iterator[Sequence[core_types.ScoredOutput]]:
        for prompt in batch_prompts:
            try:
                response = self._client.chat_completion(
                    messages=[{"role": "user", "content": prompt}],
                    model=self.model_id,
                )
                content = response["choices"][0]["message"]["content"]
            except (LlamaXPCError, KeyError, IndexError) as exc:
                raise RuntimeError(f"LlamaXPC inference failed: {exc}") from exc
            yield [core_types.ScoredOutput(score=1.0, output=content)]
