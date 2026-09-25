"""Fact-extraction prompts: the ``facts.prompts`` setting and the built-in default.

A prompt is what LangExtract is given besides the document: a description (the
instructions) and few-shot examples, each an example text with the extractions
expected from it. ``garage enrich-facts`` runs every enabled prompt that applies
to a document, and each stored fact records the prompt that produced it
(``facts.prompt_name``) and a hash of that prompt's text (``prompt_sha256``).

**Merge by name.** The built-in prompts (:data:`BUILTIN_PROMPTS`, today just
``default``) are always present unless overridden: an entry in ``facts.prompts``
with a built-in's name replaces it field by field, and any other entry is added
after the built-ins. So adding a second prompt keeps the default running, and
``{"name": "default", "enabled": false}`` turns the default off. An override may
leave ``description`` or ``examples`` out to keep the built-in's; a prompt that
is not a built-in must give both.

Nothing here talks to a model. The prompts go only to the local server
``facts.provider`` names, through the same guarded client as before.
"""

from __future__ import annotations

import hashlib
import json
import textwrap
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, Field, field_validator

CorpusClassName = Literal["document", "code", "communication"]

# A prompt's name is a CLI argument, a JSON key and a database value: keep it plain.
PROMPT_NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"


class FactExtractionExample(BaseModel):
    """One extraction the model should produce from an example's text."""

    model_config = {"extra": "forbid", "populate_by_name": True}

    extraction_class: str = Field(
        default="fact",
        alias="class",
        description="Label for what kind of thing this is; stored as facts.fact_class.",
    )
    text: str = Field(description="The extraction, quoted exactly from the example's text.")
    attributes: dict[str, str | list[str]] = Field(
        default_factory=dict,
        description="Optional attributes the model should attach; stored as facts.attributes.",
    )


class FactExample(BaseModel):
    """A few-shot example: a text and what should be extracted from it."""

    model_config = {"extra": "forbid"}

    text: str = Field(description="Example input text.")
    extractions: list[FactExtractionExample] = Field(
        default_factory=list,
        description="The extractions expected from the text, in the order they appear.",
    )


class FactPrompt(BaseModel):
    """A named fact-extraction prompt, as written in ``facts.prompts``."""

    model_config = {"extra": "forbid"}

    name: str = Field(
        pattern=PROMPT_NAME_PATTERN,
        description=(
            "Unique name, recorded on every fact the prompt produces. The name of a built-in prompt "
            "('default') overrides it instead of adding a new one."
        ),
    )
    description: str | None = Field(
        default=None,
        description=(
            "The instructions given to the model. Required for a new prompt; an override of a "
            "built-in may leave it out to keep the built-in's."
        ),
    )
    examples: list[FactExample] | None = Field(
        default=None,
        description=(
            "Few-shot examples (LangExtract's shape: text plus expected extractions). Required, and "
            "not empty, for a new prompt; an override of a built-in may leave it out to keep the "
            "built-in's."
        ),
    )
    corpus_classes: list[CorpusClassName] = Field(
        default_factory=list,
        description="Corpus classes the prompt runs on (document, code, communication); empty means all.",
    )
    sources: list[str] = Field(
        default_factory=list,
        description="Source slugs the prompt runs on; empty means every source.",
    )
    enabled: bool = Field(default=True, description="Set false to stop running this prompt.")

    @field_validator("examples")
    @classmethod
    def _examples_not_empty(cls, value: list[FactExample] | None) -> list[FactExample] | None:
        if value is not None and not value:
            raise ValueError("examples must not be empty; LangExtract needs at least one")
        return value


DEFAULT_PROMPT_NAME = "default"

DEFAULT_DESCRIPTION = textwrap.dedent("""\
    Extract every standalone fact stated in this document.

    A fact is a single, self-contained claim or piece of information that
    would still be true and meaningful if read on its own, out of context.
    Use the exact wording from the document for each fact -- do not
    paraphrase, summarize, or combine multiple facts into one. Do not invent
    or infer anything that is not explicitly stated. List facts in the order
    they appear.""")

DEFAULT_EXAMPLES = [
    FactExample(
        text=(
            "Acme Corp was founded in 1998 by Jane Doe. The company is "
            "headquartered in Austin, Texas, and has 42 employees."
        ),
        extractions=[
            FactExtractionExample(text="Acme Corp was founded in 1998 by Jane Doe."),
            FactExtractionExample(text="The company is headquartered in Austin, Texas."),
            FactExtractionExample(text="The company has 42 employees."),
        ],
    )
]

# The prompts that exist without any configuration. Deliberately generic: the
# extractor has no notion of what kind of document it is given, so it asks for
# "facts" in the abstract.
BUILTIN_PROMPTS: tuple[FactPrompt, ...] = (
    FactPrompt(name=DEFAULT_PROMPT_NAME, description=DEFAULT_DESCRIPTION, examples=DEFAULT_EXAMPLES),
)
BUILTIN_PROMPT_NAMES = frozenset(prompt.name for prompt in BUILTIN_PROMPTS)


@dataclass(frozen=True)
class EffectivePrompt:
    """A prompt as it runs: an override merged onto its built-in, everything filled in."""

    name: str
    description: str
    examples: tuple[FactExample, ...]
    corpus_classes: tuple[str, ...]
    sources: tuple[str, ...]
    enabled: bool
    builtin: bool
    # A built-in with an entry in facts.prompts.
    customized: bool

    @property
    def sha256(self) -> bytes:
        """Hash of what the model is shown (description and examples), stored beside each fact.

        Scope and ``enabled`` are left out: they decide which documents a prompt
        runs on, not what it extracts, so changing them does not make facts stale.
        """
        payload = json.dumps(
            {
                "description": self.description,
                "examples": [example.model_dump(by_alias=True) for example in self.examples],
            },
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).digest()

    def applies_to(self, corpus_class: str | None, source_slug: str | None) -> bool:
        """Whether this prompt runs on a document of ``corpus_class`` from ``source_slug``."""
        if self.corpus_classes and corpus_class not in self.corpus_classes:
            return False
        return not (self.sources and source_slug not in self.sources)

    def to_config(self) -> dict:
        """The full ``facts.prompts`` entry for this prompt, as JSON."""
        return {
            "name": self.name,
            "description": self.description,
            "examples": [example.model_dump(by_alias=True) for example in self.examples],
            "corpus_classes": list(self.corpus_classes),
            "sources": list(self.sources),
            "enabled": self.enabled,
        }


def validate_prompt_list(prompts: list[FactPrompt]) -> list[FactPrompt]:
    """Names are unique, and a prompt that is not a built-in says everything itself."""
    seen: set[str] = set()
    for prompt in prompts:
        if prompt.name in seen:
            raise ValueError(f"facts.prompts: the name {prompt.name!r} is used twice")
        seen.add(prompt.name)
        if prompt.name in BUILTIN_PROMPT_NAMES:
            continue
        missing = [key for key in ("description", "examples") if getattr(prompt, key) is None]
        if missing:
            raise ValueError(
                f"facts.prompts: {prompt.name!r} is not a built-in prompt, so it needs {' and '.join(missing)}"
            )
        if not (prompt.description or "").strip():
            raise ValueError(f"facts.prompts: {prompt.name!r} has an empty description")
    return prompts


def _resolve(prompt: FactPrompt, base: FactPrompt | None) -> EffectivePrompt:
    description = prompt.description if prompt.description is not None else (base.description if base else None)
    examples = prompt.examples if prompt.examples is not None else (base.examples if base else None)
    if description is None or examples is None:  # validate_prompt_list rules this out
        raise ValueError(f"facts.prompts: {prompt.name!r} needs a description and examples")
    return EffectivePrompt(
        name=prompt.name,
        description=description,
        examples=tuple(examples),
        corpus_classes=tuple(prompt.corpus_classes),
        sources=tuple(prompt.sources),
        enabled=prompt.enabled,
        builtin=base is not None,
        customized=base is not None and prompt is not base,
    )


def effective_prompts(configured: list[FactPrompt]) -> list[EffectivePrompt]:
    """Built-ins first (each overridden by a configured entry of its name), then the others in file order."""
    by_name = {prompt.name: prompt for prompt in configured}
    resolved = [_resolve(by_name.get(builtin.name, builtin), builtin) for builtin in BUILTIN_PROMPTS]
    resolved += [_resolve(prompt, None) for prompt in configured if prompt.name not in BUILTIN_PROMPT_NAMES]
    return resolved


def select_prompts(prompts: list[EffectivePrompt], names: list[str] | None = None) -> list[EffectivePrompt]:
    """The prompts a run uses: every enabled one, or exactly ``names`` (enabled or not).

    Naming a disabled prompt runs it: asking for it by name is the point. An
    unknown name raises ``LookupError``.
    """
    if not names:
        return [prompt for prompt in prompts if prompt.enabled]
    by_name = {prompt.name: prompt for prompt in prompts}
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise LookupError(f"unknown fact prompt(s) {', '.join(unknown)}; known: {', '.join(by_name)}")
    return [by_name[name] for name in dict.fromkeys(names)]
