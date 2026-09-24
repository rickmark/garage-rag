# Copyright 2025 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Main extraction API for LangExtract.

Modified for garage_rag: ``extract`` takes a pre-built ``model`` only. The
model-id/config path (``factory``, provider routing by model-name regex, API
keys), URL fetching (``io``), user-supplied ``output_schema``, few-shot prompt
validation and debug logging configuration are removed, so nothing here can
select or reach a cloud backend.
"""

from __future__ import annotations

from collections.abc import Iterable
import typing
import warnings

from garage_rag.enrich.langextract import annotation
from garage_rag.enrich.langextract import base_model
from garage_rag.enrich.langextract import data
from garage_rag.enrich.langextract import format_handler as fh
from garage_rag.enrich.langextract import prompting
from garage_rag.enrich.langextract import resolver
from garage_rag.enrich.langextract import tokenizer as tokenizer_lib


def extract(
    text_or_documents: str | Iterable[data.Document],
    prompt_description: str | None = None,
    examples: typing.Sequence[typing.Any] | None = None,
    *,
    model: base_model.BaseLanguageModel,
    format_type: typing.Any = None,
    max_char_buffer: int = 1000,
    fence_output: bool | None = None,
    batch_length: int = 10,
    max_workers: int = 10,
    additional_context: str | None = None,
    resolver_params: dict | None = None,
    debug: bool = False,
    extraction_passes: int = 1,
    context_window_chars: int | None = None,
    show_progress: bool = False,
    tokenizer: tokenizer_lib.Tokenizer | None = None,
) -> list[data.AnnotatedDocument] | data.AnnotatedDocument:
  """Extracts structured information from text with a pre-built ``model``.

  Args:
      text_or_documents: The source text, or an iterable of Document objects.
        Strings are always literal text, never fetched.
      prompt_description: Instructions for what to extract from the text.
      examples: List of ExampleData objects to guide the extraction.
      model: The language model to run the prompts through.
      format_type: The format type for the output (JSON or YAML).
      max_char_buffer: Max number of characters for inference.
      fence_output: Whether to expect/generate fenced output; None keeps the
        model's own setting.
      batch_length: Number of text chunks processed per batch.
      max_workers: Maximum parallel workers, where the model supports them.
      additional_context: Additional context to be added to the prompt.
      resolver_params: Parameters for the `resolver.Resolver`; see upstream
        LangExtract for the keys (alignment tuning, parse error handling).
      debug: Whether to log resolver debug detail.
      extraction_passes: Number of sequential extraction passes.
      context_window_chars: Characters of the previous chunk to include as
        context for the current one.
      show_progress: Accepted for compatibility; there is no progress bar.
      tokenizer: Optional Tokenizer; defaults to RegexTokenizer.

  Returns:
      An AnnotatedDocument for a string, or a list of them for Documents.

  Raises:
      ValueError: If examples is None or empty.
  """
  if not examples:
    raise ValueError(
        "Examples are required for reliable extraction. Please provide at least"
        " one ExampleData object with sample extractions."
    )
  examples = list(examples)

  if format_type is None:
    format_type = data.FormatType.JSON

  if max_workers is not None and batch_length < max_workers:
    warnings.warn(
        f"batch_length ({batch_length}) < max_workers ({max_workers}). "
        f"Only {batch_length} workers will be used. "
        "Set batch_length >= max_workers for optimal parallelization.",
        UserWarning,
    )

  prompt_template = prompting.PromptTemplateStructured(
      description=prompt_description
  )
  prompt_template.examples.extend(examples)

  language_model = model
  if fence_output is not None:
    language_model.set_fence_output(fence_output)

  format_handler, remaining_params = fh.FormatHandler.from_resolver_params(
      resolver_params=resolver_params,
      base_format_type=format_type,
      base_use_fences=language_model.requires_fence_output,
      base_attribute_suffix=data.ATTRIBUTE_SUFFIX,
      base_use_wrapper=True,
      base_wrapper_key=data.EXTRACTIONS_KEY,
  )

  if language_model.schema is not None:
    language_model.schema.validate_format(format_handler)

  # Pull alignment settings from normalized params
  alignment_kwargs = {}
  for key in resolver.ALIGNMENT_PARAM_KEYS:
    val = remaining_params.pop(key, None)
    if val is not None:
      alignment_kwargs[key] = val
  alignment_kwargs.setdefault("suppress_parse_errors", True)

  effective_params = {"format_handler": format_handler, **remaining_params}

  try:
    res = resolver.Resolver(**effective_params)
  except TypeError as e:
    msg = str(e)
    if (
        "unexpected keyword argument" in msg
        or "got an unexpected keyword argument" in msg
    ):
      raise TypeError(
          f"Unknown key in resolver_params; check spelling: {e}"
      ) from e
    raise

  annotator = annotation.Annotator(
      language_model=language_model,
      prompt_template=prompt_template,
      format_handler=format_handler,
  )

  if isinstance(text_or_documents, str):
    return annotator.annotate_text(
        text=text_or_documents,
        resolver=res,
        max_char_buffer=max_char_buffer,
        batch_length=batch_length,
        additional_context=additional_context,
        debug=debug,
        extraction_passes=extraction_passes,
        context_window_chars=context_window_chars,
        show_progress=show_progress,
        max_workers=max_workers,
        tokenizer=tokenizer,
        **alignment_kwargs,
    )
  if additional_context is not None:
    documents = (
        doc.with_additional_context(additional_context)
        if doc.additional_context is None
        else doc
        for doc in text_or_documents
    )
  else:
    documents = text_or_documents
  return list(
      annotator.annotate_documents(
          documents=documents,
          resolver=res,
          max_char_buffer=max_char_buffer,
          batch_length=batch_length,
          debug=debug,
          extraction_passes=extraction_passes,
          context_window_chars=context_window_chars,
          show_progress=show_progress,
          max_workers=max_workers,
          tokenizer=tokenizer,
          **alignment_kwargs,
      )
  )
