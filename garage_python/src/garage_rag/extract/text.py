"""Plain text, Markdown, and source code extraction."""

from __future__ import annotations

import codecs
import logging
from pathlib import Path

import yaml

from garage_rag.extract.base import (
    ContentKind,
    ExtractionError,
    ExtractResult,
    guess_title,
    normalize_text,
)

log = logging.getLogger(__name__)

VERSION = "1"

_UTF16_BOMS = (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)


def read_text_file(path: Path) -> tuple[str, str]:
    """Read a text file, returning ``(text, encoding_used)``.

    Order matters. ``utf-8-sig`` goes first so a UTF-8 BOM is stripped rather
    than surviving as ``\\ufeff`` in front of Markdown frontmatter. UTF-16 is
    only attempted when the file announces itself with a BOM: Python's
    ``utf-16`` codec accepts almost any even-length byte string without one,
    so trying it blind turns a plain latin-1 file into CJK noise.
    """
    data = path.read_bytes()

    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        pass
    else:
        return text, "utf-8-sig" if data.startswith(codecs.BOM_UTF8) else "utf-8"

    if data[:2] in _UTF16_BOMS:
        try:
            return data.decode("utf-16"), "utf-16"
        except UnicodeDecodeError:
            log.debug("%s has a UTF-16 BOM but does not decode as UTF-16", path)

    # Single-byte fallbacks. Personal corpora accumulate legacy files, and
    # failing a document over one bad byte loses the whole thing. cp1252 is
    # what most Western legacy text was actually written in (it rejects a few
    # bytes, 0x81/0x8D/0x8F/0x90/0x9D); latin-1 accepts every byte, so it is
    # the terminal fallback rather than a step that can fail.
    try:
        return data.decode("cp1252"), "cp1252"
    except UnicodeDecodeError:
        return data.decode("latin-1"), "latin-1"


def split_frontmatter(text: str) -> tuple[dict, str]:
    """Split leading YAML frontmatter from a Markdown body.

    Returns ``({}, text)`` when there is no frontmatter or it does not parse --
    malformed frontmatter should not cost us the document body.
    """
    if not text.startswith("---"):
        return {}, text

    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, text

    for index in range(1, min(len(lines), 200)):
        if lines[index].strip() in {"---", "..."}:
            block = "\n".join(lines[1:index])
            body = "\n".join(lines[index + 1 :])
            try:
                parsed = yaml.safe_load(block)
            except yaml.YAMLError:
                log.debug("unparseable frontmatter, keeping body")
                return {}, text
            if isinstance(parsed, dict):
                return parsed, body
            return {}, text

    return {}, text


def _author_hints_from_frontmatter(front: dict) -> list[str]:
    """Pull author-ish values out of frontmatter.

    Weak signal in practice -- almost no Markdown in the observed corpus carries
    an `author:` key -- so this augments path and git rules rather than leading.
    """
    hints: list[str] = []
    for key in ("author", "authors", "by", "creator"):
        value = front.get(key)
        if isinstance(value, str):
            hints.append(value)
        elif isinstance(value, list):
            hints.extend(str(item) for item in value if item)
    return [h.strip() for h in hints if str(h).strip()]


def extract_markdown(path: Path) -> ExtractResult:
    raw, encoding = read_text_file(path)
    front, body = split_frontmatter(raw)
    text = normalize_text(body)

    title = None
    if isinstance(front.get("title"), str):
        title = front["title"].strip()

    meta: dict = {"encoding": encoding}
    if front:
        # Keep only JSON-safe scalars; frontmatter can hold arbitrary YAML.
        meta["frontmatter"] = {
            k: v for k, v in front.items() if isinstance(v, (str, int, float, bool))
        }

    return ExtractResult(
        text=text,
        kind=ContentKind.MARKDOWN,
        extractor="markdown",
        extractor_version=VERSION,
        title=title or guess_title(path, text, kind=ContentKind.MARKDOWN),
        meta=meta,
        author_hints=_author_hints_from_frontmatter(front),
    )


def extract_plaintext(path: Path) -> ExtractResult:
    raw, encoding = read_text_file(path)
    text = normalize_text(raw)
    return ExtractResult(
        text=text,
        kind=ContentKind.PROSE,
        extractor="plaintext",
        extractor_version=VERSION,
        title=guess_title(path, text, kind=ContentKind.PROSE),
        meta={"encoding": encoding},
    )


def extract_code(path: Path) -> ExtractResult:
    """Source code, kept verbatim.

    No normalization beyond encoding and line endings: indentation is meaningful,
    and collapsing blank lines would corrupt the structure that language-aware
    chunking relies on.
    """
    raw, encoding = read_text_file(path)
    text = raw.replace("\r\n", "\n").replace("\r", "\n").replace("\x00", "")
    if not text.strip():
        raise ExtractionError(f"empty source file: {path}")
    return ExtractResult(
        text=text,
        kind=ContentKind.CODE,
        extractor="code",
        extractor_version=VERSION,
        title=path.name,
        meta={"encoding": encoding, "extension": path.suffix.lower()},
    )
