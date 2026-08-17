"""Image text extraction: Tesseract locally, Claude only as a bounded fallback.

Tesseract handles clean screenshots well and costs nothing. It struggles with
low-contrast captures, dense UI, diagrams, and handwriting -- exactly the cases
where a vision model earns its keep. So Tesseract runs first and its *confidence*
decides whether escalation is worth it.

Two properties keep this honest:

* Escalation is opt-in per source and globally, and is impossible for
  communications -- see :mod:`garage_rag.enrich.egress`.
* An image that yields no usable text is reported as a failure rather than
  indexed as an empty document, so the run report reflects reality.

Note on the corpus: most images in a source tree are UI assets -- icons, arrows,
logos. Those have no recoverable text and should not consume OCR time at all, so
tiny images are rejected before Tesseract runs.
"""

from __future__ import annotations

import base64
import logging
import os
from pathlib import Path

from ..config import get_settings
from .base import ContentKind, ExtractionError, ExtractResult, normalize_text

log = logging.getLogger(__name__)

VERSION = "1"

# Below this, an image is an icon or a spacer, not a document. Screenshots and
# scans are comfortably larger in both dimensions.
MIN_OCR_WIDTH = 200
MIN_OCR_HEIGHT = 200
# Guard against decompression bombs and multi-hundred-megapixel scans.
MAX_OCR_PIXELS = 40_000_000

_MEDIA_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
}


def _open_image(path: Path):
    from PIL import Image

    try:
        image = Image.open(path)
        image.load()
    except Exception as exc:  # noqa: BLE001 - Pillow raises many types
        raise ExtractionError(f"unreadable image {path}: {exc}") from exc
    return image


def _tesseract(path: Path) -> tuple[str, float]:
    """Run Tesseract, returning ``(text, mean_word_confidence)``.

    Confidence comes from the per-word data rather than the plain text call:
    "returned something" and "returned something legible" are different, and only
    the word data distinguishes them.
    """
    import pytesseract
    from pytesseract import Output

    # Tesseract is internally multi-threaded. Inside a process pool that
    # oversubscribes the CPU and slows everything down.
    os.environ.setdefault("OMP_THREAD_LIMIT", "1")

    image = _open_image(path)
    width, height = image.size
    if width * height > MAX_OCR_PIXELS:
        raise ExtractionError(
            f"image too large to OCR ({width}x{height}): {path}"
        )
    if width < MIN_OCR_WIDTH or height < MIN_OCR_HEIGHT:
        raise ExtractionError(f"image too small to hold text ({width}x{height}): {path}")

    try:
        data = pytesseract.image_to_data(image, output_type=Output.DICT)
    except Exception as exc:  # noqa: BLE001
        raise ExtractionError(f"tesseract failed on {path}: {exc}") from exc

    words: list[str] = []
    confidences: list[float] = []
    for word, conf in zip(data.get("text", []), data.get("conf", []), strict=False):
        cleaned = (word or "").strip()
        if not cleaned:
            continue
        try:
            value = float(conf)
        except (TypeError, ValueError):
            continue
        # -1 marks a region Tesseract found but could not read.
        if value < 0:
            continue
        words.append(cleaned)
        confidences.append(value)

    text = " ".join(words)
    mean_conf = sum(confidences) / len(confidences) if confidences else 0.0
    return normalize_text(text), mean_conf


def _claude_vision(path: Path, *, source_allows_cloud: bool) -> str:
    """Transcribe an image with Claude. Routed through the egress chokepoint."""
    from ..db.models import CorpusClass
    from ..enrich.egress import EgressRequest, send

    suffix = path.suffix.lower()
    media_type = _MEDIA_TYPES.get(suffix)
    if media_type is None:
        raise ExtractionError(f"cloud OCR does not support {suffix}: {path}")

    encoded = base64.standard_b64encode(path.read_bytes()).decode("ascii")

    # Images reaching here are never communications; constructing the request
    # with the true class is what enforces that.
    request = EgressRequest(
        corpus_class=CorpusClass.DOCUMENT,
        purpose="image-ocr",
        source_allows_cloud=source_allows_cloud,
        max_tokens=4096,
        content=[
            {
                "type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": encoded},
            },
            {
                "type": "text",
                "text": (
                    "Transcribe all text in this image verbatim. If it is a "
                    "diagram or chart rather than text, describe its content and "
                    "any labels. If there is no text and no meaningful content, "
                    "reply with exactly: NO_TEXT"
                ),
            },
        ],
    )
    return send(
        request,
        system=(
            "You extract text from images for a search index. Output only the "
            "transcription or description, with no preamble."
        ),
    )


def extract_image(
    path: Path,
    *,
    source_allows_cloud: bool = False,
) -> ExtractResult:
    """Extract text from an image, escalating to a vision model when permitted."""
    settings = get_settings()

    text, confidence = _tesseract(path)
    meta: dict = {"ocr_engine": "tesseract", "ocr_confidence": round(confidence, 2)}

    good_enough = (
        len(text) >= settings.ocr_min_chars and confidence >= settings.ocr_min_confidence
    )

    if not good_enough:
        from ..enrich.egress import EgressBlocked, cloud_enabled

        if cloud_enabled() and source_allows_cloud:
            try:
                better = _claude_vision(path, source_allows_cloud=source_allows_cloud)
            except EgressBlocked:
                raise
            except Exception as exc:  # noqa: BLE001 - a failed fallback is not fatal
                log.debug("cloud OCR failed for %s: %s", path.name, exc)
                better = ""

            if better and better.strip() != "NO_TEXT":
                text = normalize_text(better)
                meta["ocr_engine"] = "tesseract+claude"
                meta["ocr_escalated"] = True
                meta["cloud_model"] = settings.cloud_ocr_model
        else:
            meta["ocr_escalation_skipped"] = (
                "cloud disabled" if not cloud_enabled() else "source disallows cloud"
            )

    if len(text) < settings.ocr_min_chars:
        # Reported as a failure, not indexed as an empty document: most images in
        # a code tree are icons and genuinely contain nothing.
        raise ExtractionError(
            f"no usable text in image (confidence {confidence:.0f}, "
            f"{len(text)} chars): {path}"
        )

    return ExtractResult(
        text=text,
        kind=ContentKind.PROSE,
        extractor=meta["ocr_engine"],
        extractor_version=VERSION,
        title=path.stem,
        meta=meta,
    )
