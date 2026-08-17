"""Chunking, specialized per content kind.

The strategies differ because the failure modes differ:

* **Markdown** -- split on headers first so a chunk never straddles two
  sections, then split oversized sections by size. Each chunk keeps its heading
  breadcrumb, which is often the only thing identifying what the text is about.
* **Code** -- language-aware splitting keeps functions and classes intact.
* **Prose / PDF** -- plain recursive splitting on paragraph boundaries.
* **Tabular** -- split on sheet headings, never mid-row.
* **Conversation** -- handled by :mod:`garage_rag.extract.messages`, which
  windows messages before they ever reach here.

``MarkdownHeaderTextSplitter`` deliberately does not derive from ``TextSplitter``
in langchain-text-splitters, so it cannot be swapped in as a size-based splitter;
the two-stage pass below is the supported pattern.
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass

from langchain_text_splitters import (
    Language,
    MarkdownHeaderTextSplitter,
    RecursiveCharacterTextSplitter,
)

from ..config import get_settings
from ..extract.base import ContentKind

log = logging.getLogger(__name__)

# Headers to split on, and the metadata key each maps to.
_MD_HEADERS = [("#", "h1"), ("##", "h2"), ("###", "h3")]

# Extension -> langchain Language for structure-aware code splitting. Only
# languages langchain actually models are listed; everything else falls back to
# recursive character splitting, which is still reasonable for code.
_CODE_LANGUAGES: dict[str, Language] = {
    ".py": Language.PYTHON,
    ".pyi": Language.PYTHON,
    ".js": Language.JS,
    ".jsx": Language.JS,
    ".mjs": Language.JS,
    ".cjs": Language.JS,
    ".ts": Language.TS,
    ".tsx": Language.TS,
    ".c": Language.C,
    ".h": Language.C,
    ".cc": Language.CPP,
    ".cpp": Language.CPP,
    ".cxx": Language.CPP,
    ".hpp": Language.CPP,
    ".hh": Language.CPP,
    ".go": Language.GO,
    ".rs": Language.RUST,
    ".rb": Language.RUBY,
    ".php": Language.PHP,
    ".java": Language.JAVA,
    ".kt": Language.KOTLIN,
    ".scala": Language.SCALA,
    ".swift": Language.SWIFT,
    ".cs": Language.CSHARP,
    ".lua": Language.LUA,
    ".pl": Language.PERL,
    ".hs": Language.HASKELL,
    ".ex": Language.ELIXIR,
    ".exs": Language.ELIXIR,
    ".html": Language.HTML,
    ".htm": Language.HTML,
    ".tex": Language.LATEX,
    ".sol": Language.SOL,
    ".cob": Language.COBOL,
}


@dataclass
class TextChunk:
    """One embeddable unit."""

    ord: int
    text: str
    chunker: str
    heading_path: str | None = None
    char_start: int | None = None
    char_end: int | None = None

    @property
    def sha256(self) -> bytes:
        return hashlib.sha256(self.text.encode("utf-8")).digest()

    @property
    def token_estimate(self) -> int:
        """Rough token count.

        Deliberately an estimate: loading a real tokenizer per worker process
        costs more than this number is worth, and it is only used for reporting
        and for capping embedding batch payloads.
        """
        return max(1, len(self.text) // 4)


def _recursive_splitter(size: int, overlap: int) -> RecursiveCharacterTextSplitter:
    return RecursiveCharacterTextSplitter(
        chunk_size=size,
        chunk_overlap=overlap,
        # Prefer paragraph, then line, then sentence, then word boundaries.
        separators=["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""],
        keep_separator=True,
        length_function=len,
    )


def _heading_path(metadata: dict) -> str | None:
    parts = [metadata[key] for key in ("h1", "h2", "h3") if metadata.get(key)]
    return " > ".join(parts) if parts else None


def chunk_markdown(text: str, *, size: int, overlap: int) -> list[TextChunk]:
    """Header split, then size split, preserving heading breadcrumbs."""
    header_splitter = MarkdownHeaderTextSplitter(
        headers_to_split_on=_MD_HEADERS,
        strip_headers=False,
    )
    size_splitter = _recursive_splitter(size, overlap)

    try:
        sections = header_splitter.split_text(text)
    except Exception as exc:  # noqa: BLE001 - malformed markdown is still text
        log.debug("markdown header split failed, falling back to recursive: %s", exc)
        return chunk_prose(text, size=size, overlap=overlap)

    chunks: list[TextChunk] = []
    for section in sections:
        heading = _heading_path(section.metadata or {})
        body = section.page_content
        pieces = size_splitter.split_text(body) if len(body) > size else [body]
        for piece in pieces:
            if piece.strip():
                chunks.append(
                    TextChunk(
                        ord=len(chunks),
                        text=piece.strip(),
                        chunker=f"markdown-header+recursive:{size}/{overlap}",
                        heading_path=heading,
                    )
                )

    if not chunks:
        return chunk_prose(text, size=size, overlap=overlap)
    return chunks


def chunk_prose(text: str, *, size: int, overlap: int) -> list[TextChunk]:
    splitter = _recursive_splitter(size, overlap)
    return [
        TextChunk(ord=index, text=piece.strip(), chunker=f"recursive:{size}/{overlap}")
        for index, piece in enumerate(splitter.split_text(text))
        if piece.strip()
    ]


def chunk_code(text: str, *, extension: str, size: int, overlap: int) -> list[TextChunk]:
    """Language-aware where langchain models the language, recursive otherwise."""
    language = _CODE_LANGUAGES.get(extension.lower())
    if language is not None:
        try:
            splitter = RecursiveCharacterTextSplitter.from_language(
                language=language, chunk_size=size, chunk_overlap=overlap
            )
            label = f"code:{language.value}:{size}/{overlap}"
        except Exception as exc:  # noqa: BLE001
            log.debug("language splitter unavailable for %s: %s", extension, exc)
            splitter = _recursive_splitter(size, overlap)
            label = f"recursive:{size}/{overlap}"
    else:
        splitter = _recursive_splitter(size, overlap)
        label = f"recursive:{size}/{overlap}"

    return [
        TextChunk(ord=index, text=piece, chunker=label)
        for index, piece in enumerate(splitter.split_text(text))
        if piece.strip()
    ]


def chunk_tabular(text: str, *, size: int, overlap: int) -> list[TextChunk]:
    """Split spreadsheet text on sheet headings and row boundaries.

    Zero overlap and a newline-first separator list: repeating rows across chunks
    adds noise, and a chunk boundary mid-row produces meaningless fragments.
    """
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=size,
        chunk_overlap=0,
        separators=["\n## ", "\n\n", "\n", " "],
        keep_separator=True,
    )
    chunks: list[TextChunk] = []
    for piece in splitter.split_text(text):
        stripped = piece.strip()
        if not stripped:
            continue
        heading = None
        if stripped.startswith("## "):
            heading = stripped.split("\n", 1)[0][3:].strip() or None
        chunks.append(
            TextChunk(
                ord=len(chunks),
                text=stripped,
                chunker=f"tabular:{size}",
                heading_path=heading,
            )
        )
    return chunks


def chunk_text(
    text: str,
    kind: ContentKind,
    *,
    extension: str = "",
    size: int | None = None,
    overlap: int | None = None,
) -> list[TextChunk]:
    """Chunk ``text`` according to its :class:`ContentKind`."""
    settings = get_settings()

    if kind is ContentKind.CODE:
        size = size or settings.code_chunk_size
        overlap = overlap if overlap is not None else settings.code_chunk_overlap
        return chunk_code(text, extension=extension, size=size, overlap=overlap)

    size = size or settings.chunk_size
    overlap = overlap if overlap is not None else settings.chunk_overlap

    if kind is ContentKind.MARKDOWN:
        return chunk_markdown(text, size=size, overlap=overlap)
    if kind is ContentKind.TABULAR:
        return chunk_tabular(text, size=size, overlap=overlap)
    # CONVERSATION text arrives pre-windowed; treat the windows as prose.
    return chunk_prose(text, size=size, overlap=overlap)


def renumber(chunks: list[TextChunk]) -> list[TextChunk]:
    """Reassign sequential ``ord`` values, satisfying the (document_id, ord) key."""
    for index, chunk in enumerate(chunks):
        chunk.ord = index
    return chunks
