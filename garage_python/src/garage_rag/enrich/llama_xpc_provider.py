"""LangExtract provider that runs fact-distillation prompts through LlamaXPC.

`LlamaXPCClient` (`garage_rag.xpc.llama_xpc`) is an HTTP client of the
llama-server-compatible API the app's LlamaXPCService serves on loopback
(`settings.llama_host`), so this provider posts each prompt to its
`/v1/chat/completions` route. Everything else (prompting, few-shot examples,
JSON parsing, grounding) is the vendored LangExtract's
(`garage_rag.enrich.langextract`); only the transport is ours. The client refuses any
non-loopback host, so content handed to it never leaves the machine.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator, Sequence
from typing import Any

from garage_rag.enrich.langextract import base_model, schema
from garage_rag.enrich.langextract import types as core_types
from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError


@dataclasses.dataclass(init=False)
class LlamaXPCLanguageModel(base_model.BaseLanguageModel):
    """Runs LangExtract prompts through the local LlamaXPCService over loopback HTTP."""

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
        # ``kwargs`` absorbs the provider-generic options LangExtract may pass
        # (temperature, max_workers, ...); none of them apply to this transport.
        self._client = client or LlamaXPCClient()

    def infer(self, batch_prompts: Sequence[str], **kwargs: Any) -> Iterator[Sequence[core_types.ScoredOutput]]:
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
