"""Deriving ``corpus_class`` for a resource.

``corpus_class`` answers "what is this?" and is independent of trust. The two
axes together are what make the corpus queryable in the way that matters:

============================  ==========================================
(class, trust)                meaning
============================  ==========================================
(code, authored)              source you wrote
(code, reference)             vendored or third-party dependency
(document, authored)          your notes, papers, reports
(document, reference)         downloaded papers, product documentation
(communication, authored)     messages and mail you sent
(communication, received)     messages and mail sent to you
============================  ==========================================

Classification is by content shape first (a ``.py`` file is code wherever it
lives), with the source's declared default as the fallback. A source may also
pin a class outright -- the Messages source is communication regardless of what
any individual row looks like.
"""

from __future__ import annotations

from pathlib import Path

from ..db.models import CorpusClass
from ..extract.base import ContentKind

# Documentation-shaped files keep their document class even inside a source-code
# repository: a README is prose about code, not code.
_DOC_EXTENSIONS_IN_CODE_TREES = frozenset(
    {".md", ".markdown", ".mdx", ".rst", ".org", ".adoc", ".asciidoc", ".txt", ".pdf"}
)

# Filenames that are documentation regardless of extension.
_DOC_STEMS = frozenset(
    {"readme", "license", "licence", "copying", "notice", "changelog", "changes",
     "contributing", "authors", "codeowners", "security", "history", "news",
     "todo", "roadmap", "architecture", "design"}
)


def class_for_content_kind(kind: ContentKind) -> CorpusClass:
    """Map a chunking kind onto a corpus class."""
    if kind is ContentKind.CODE:
        return CorpusClass.CODE
    if kind is ContentKind.CONVERSATION:
        return CorpusClass.COMMUNICATION
    return CorpusClass.DOCUMENT


def classify(
    path: Path,
    kind: ContentKind,
    *,
    source_default: CorpusClass = CorpusClass.DOCUMENT,
    source_pins_class: bool = False,
) -> CorpusClass:
    """Decide the corpus class for one resource.

    ``source_pins_class`` forces the source's default, used for sources whose
    class is intrinsic (Messages, Mail) rather than inferred per file.
    """
    if source_pins_class:
        return source_default

    # Communications are never reclassified by file shape.
    if kind is ContentKind.CONVERSATION or source_default is CorpusClass.COMMUNICATION:
        return CorpusClass.COMMUNICATION

    suffix = path.suffix.lower()
    stem = path.stem.lower()

    # Prose inside a code tree stays prose.
    if suffix in _DOC_EXTENSIONS_IN_CODE_TREES or stem in _DOC_STEMS:
        return CorpusClass.DOCUMENT

    return class_for_content_kind(kind)


def is_code_path(path: Path) -> bool:
    """Whether a path would classify as code. Used by the walker's filters."""
    from ..extract.dispatch import CODE_EXTENSIONS

    suffix = path.suffix.lower()
    if suffix in _DOC_EXTENSIONS_IN_CODE_TREES or path.stem.lower() in _DOC_STEMS:
        return False
    return suffix in CODE_EXTENSIONS
