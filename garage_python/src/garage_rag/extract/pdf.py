"""PDF extraction: pypdf first, pdfplumber where pypdf comes up short.

pypdf (BSD-3) is fast and handles the majority of well-formed PDFs. pdfplumber
(MIT) is slower but far better on column layouts and tables. Both are
permissively licensed, which is why PyMuPDF -- faster still, but AGPL -- is
deliberately not used here.

The escalation is per-page rather than per-document: a 300-page report with two
scanned inserts should not pay pdfplumber's cost on all 300 pages.
"""

from __future__ import annotations

import logging
import warnings
from pathlib import Path

from garage_rag.config import get_settings
from .base import (
    ContentKind,
    ExtractionError,
    ExtractResult,
    clean_author_hints,
    normalize_text,
)

log = logging.getLogger(__name__)

VERSION = "1"


def _clean_metadata_value(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.startswith("\x00"):
        return None
    # Producers often stuff tool names into /Author; those are not people.
    lowered = text.lower()
    if any(token in lowered for token in ("acrobat", "microsoft word", "latex", "pdftex")):
        return None
    return text[:500]


def _pdf_metadata(reader) -> tuple[dict, list[str], str | None]:  # noqa: ANN001
    """Extract (meta, author_hints, title) from a pypdf reader."""
    meta: dict = {}
    hints: list[str] = []
    title: str | None = None

    try:
        info = reader.metadata
    except Exception:  # noqa: BLE001 - malformed metadata is common
        return meta, hints, title

    if not info:
        return meta, hints, title

    author = _clean_metadata_value(getattr(info, "author", None))
    if author:
        meta["pdf_author"] = author
        # Split "A; B" and "A and B" into separate candidates.
        for part in author.replace(" and ", ";").replace(",", ";").split(";"):
            cleaned = part.strip()
            if len(cleaned) > 2:
                hints.append(cleaned)

    title = _clean_metadata_value(getattr(info, "title", None))
    if title:
        meta["pdf_title"] = title

    for attr, key in (("creator", "pdf_creator"), ("producer", "pdf_producer")):
        value = _clean_metadata_value(getattr(info, attr, None))
        if value:
            meta[key] = value

    try:
        created = info.get("/CreationDate")
        if created:
            meta["pdf_creation_date"] = str(created)[:64]
    except Exception:  # noqa: BLE001
        pass

    return meta, hints, title


def _plumber_page_text(path: Path, page_index: int) -> str:
    """Re-extract one page with pdfplumber, including any tables."""
    import pdfplumber

    with pdfplumber.open(str(path)) as pdf:
        if page_index >= len(pdf.pages):
            return ""
        page = pdf.pages[page_index]
        parts: list[str] = []

        text = page.extract_text() or ""
        if text.strip():
            parts.append(text)

        # Tables carry meaning that flat text extraction destroys.
        try:
            for table in page.extract_tables() or []:
                rows = [
                    " | ".join((cell or "").strip() for cell in row)
                    for row in table
                    if any(cell for cell in row)
                ]
                if rows:
                    parts.append("\n".join(rows))
        except Exception as exc:  # noqa: BLE001
            log.debug("table extraction failed on page %d: %s", page_index, exc)

        return "\n\n".join(parts)


def extract_pdf(path: Path) -> ExtractResult:
    from pypdf import PdfReader
    from pypdf.errors import PdfReadError

    settings = get_settings()
    threshold = settings.pdf_min_chars_per_page

    try:
        # pypdf is chatty about malformed-but-readable PDFs; the warnings are not
        # actionable per-document in a bulk ingest.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            reader = PdfReader(str(path))
            if reader.is_encrypted:
                # Empty-password decryption covers PDFs that are "encrypted"
                # only to set permissions flags.
                try:
                    if reader.decrypt("") == 0:
                        raise ExtractionError(f"password-protected PDF: {path}")
                except NotImplementedError as exc:
                    raise ExtractionError(f"unsupported PDF encryption: {path}") from exc

            page_count = len(reader.pages)
            meta, hints, title = _pdf_metadata(reader)

            pages: list[str] = []
            escalated: list[int] = []
            for index, page in enumerate(reader.pages):
                try:
                    text = page.extract_text() or ""
                except Exception as exc:  # noqa: BLE001 - one bad page, not a bad file
                    log.debug("pypdf failed on %s page %d: %s", path.name, index, exc)
                    text = ""

                if len(text.strip()) < threshold:
                    try:
                        better = _plumber_page_text(path, index)
                    except Exception as exc:  # noqa: BLE001
                        log.debug("pdfplumber failed on %s page %d: %s", path.name, index, exc)
                        better = ""
                    if len(better.strip()) > len(text.strip()):
                        text = better
                        escalated.append(index)

                pages.append(text)

    except PdfReadError as exc:
        raise ExtractionError(f"unreadable PDF {path}: {exc}") from exc
    except ExtractionError:
        raise
    except Exception as exc:  # noqa: BLE001
        raise ExtractionError(f"PDF extraction failed for {path}: {exc}") from exc

    text = normalize_text("\n\n".join(pages))
    meta["page_count"] = page_count
    if escalated:
        meta["pdfplumber_pages"] = escalated[:50]
        meta["pdfplumber_page_count"] = len(escalated)

    # A PDF that yields almost nothing is probably scanned images. Flagged rather
    # than failed, so an OCR pass can pick it up later.
    if len(text) < threshold and page_count > 0:
        meta["likely_scanned"] = True
        log.info(
            "%s yielded %d chars over %d pages; likely scanned",
            path.name,
            len(text),
            page_count,
        )

    extractor = "pypdf+pdfplumber" if escalated else "pypdf"
    return ExtractResult(
        text=text,
        kind=ContentKind.PROSE,
        extractor=extractor,
        extractor_version=VERSION,
        title=title or path.stem,
        meta=meta,
        author_hints=clean_author_hints(hints),
    )
