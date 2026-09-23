"""Image text extraction with Tesseract, on this machine.

Tesseract handles clean screenshots and scans well. It struggles with
low-contrast captures, dense UI, diagrams and handwriting; those images yield
little or no text, and there is no fallback -- no image is ever sent to a cloud
vision model.

An image that yields no usable text is reported as a failure rather than
indexed as an empty document, so the run report reflects reality.

Note on the corpus: most images in a source tree are UI assets -- icons, arrows,
logos. Those have no recoverable text and should not consume OCR time at all, so
tiny images are rejected before Tesseract runs.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

from garage_rag.config import get_settings
from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, normalize_text

log = logging.getLogger(__name__)

VERSION = "1"

# Below this, an image is an icon or a spacer, not a document. Screenshots and
# scans are comfortably larger in both dimensions.
MIN_OCR_WIDTH = 200
MIN_OCR_HEIGHT = 200
# Guard against decompression bombs and multi-hundred-megapixel scans.
MAX_OCR_PIXELS = 40_000_000


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

    # The app bundles its own tesseract and says where (GarageApp's Python runtime
    # exports it, and TESSDATA_PREFIX for its language data); anywhere else,
    # pytesseract's PATH lookup applies.
    bundled = os.environ.get("GARAGE_TESSERACT_CMD")
    if bundled:
        pytesseract.pytesseract.tesseract_cmd = bundled

    # Tesseract is internally multi-threaded. Inside a process pool that
    # oversubscribes the CPU and slows everything down.
    os.environ.setdefault("OMP_THREAD_LIMIT", "1")

    image = _open_image(path)
    width, height = image.size
    if width * height > MAX_OCR_PIXELS:
        raise ExtractionError(f"image too large to OCR ({width}x{height}): {path}")
    if width < MIN_OCR_WIDTH or height < MIN_OCR_HEIGHT:
        raise ExtractionError(f"image too small to hold text ({width}x{height}): {path}")

    # pytesseract writes the image to a temp file in its original format. The
    # bundled Leptonica reads PNG only, so hand it an image with no format of its
    # own, which pytesseract saves as PNG. GIF and WebP inputs take the same path.
    if image.mode not in ("1", "L", "RGB", "RGBA"):
        image = image.convert("RGBA" if "A" in image.getbands() else "RGB")
    else:
        image = image.copy()
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


def extract_image(path: Path) -> ExtractResult:
    """Extract text from an image with Tesseract."""
    settings = get_settings()

    text, confidence = _tesseract(path)
    if len(text) < settings.ocr_min_chars:
        # Reported as a failure, not indexed as an empty document: most images in
        # a code tree are icons and genuinely contain nothing.
        raise ExtractionError(f"no usable text in image (confidence {confidence:.0f}, {len(text)} chars): {path}")

    return ExtractResult(
        text=text,
        kind=ContentKind.PROSE,
        extractor="tesseract",
        extractor_version=VERSION,
        title=path.stem,
        meta={"ocr_engine": "tesseract", "ocr_confidence": round(confidence, 2)},
    )
