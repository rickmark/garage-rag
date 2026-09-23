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

"""Vendored subset of LangExtract 1.7.0 (https://github.com/google/langextract).

Only what local fact distillation needs: prompting, chunking, the resolver and
its alignment, and the annotator loop, driven by a caller-built model
(``garage_rag.enrich.ollama_provider``, ``garage_rag.enrich.llama_xpc_provider``).

Modified for garage_rag. Upstream's ``core`` package is flattened into this one.
Left out entirely: the provider registry and model-id routing (``factory``,
``providers``, including the Gemini and OpenAI backends), URL fetching and
dataframe I/O (``io``, which needs pandas), visualization, the tqdm progress
bar, prompt validation and debug utilities. absl logging is replaced by the
standard library's, and more_itertools by ``itertools``. Files that were changed
say so in their docstrings. See LICENSE in this directory and the repository's
NOTICE.
"""

from garage_rag.enrich.langextract import data
from garage_rag.enrich.langextract.extraction import extract

__all__ = ["data", "extract"]
