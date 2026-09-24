"""The local OCR pass in garage_rag.extract.image: gating and word filtering."""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from garage_rag.extract import image as image_extract
from garage_rag.extract import tesseract
from garage_rag.extract.base import ExtractionError


def _write(tmp_path: Path, name: str, size: tuple[int, int] = (400, 300)) -> Path:
    path = tmp_path / name
    Image.new("RGB", size, "white").save(path)
    return path


def test_joins_readable_words_and_averages_their_confidence(monkeypatch, tmp_path):
    words = [
        tesseract.Word("Hello", 90.0),
        tesseract.Word("  ", 50.0),
        tesseract.Word("?", -1.0),
        tesseract.Word("world", 80.0),
    ]
    monkeypatch.setattr(tesseract, "recognize", lambda image: words)

    text, confidence = image_extract._tesseract(_write(tmp_path, "shot.png"))

    assert text == "Hello world"
    assert confidence == pytest.approx(85.0)


def test_nothing_readable_is_zero_confidence(monkeypatch, tmp_path):
    monkeypatch.setattr(tesseract, "recognize", lambda image: [])
    assert image_extract._tesseract(_write(tmp_path, "blank.png")) == ("", 0.0)


def test_icons_are_rejected_before_ocr(monkeypatch, tmp_path):
    def fail(image):
        raise AssertionError("OCR must not run on an icon")

    monkeypatch.setattr(tesseract, "recognize", fail)
    with pytest.raises(ExtractionError, match="too small"):
        image_extract._tesseract(_write(tmp_path, "icon.png", (64, 64)))


def test_library_failures_become_extraction_errors(monkeypatch, tmp_path):
    def unavailable(image):
        raise tesseract.TesseractUnavailable("libtesseract not found")

    monkeypatch.setattr(tesseract, "recognize", unavailable)
    with pytest.raises(ExtractionError, match="libtesseract not found"):
        image_extract._tesseract(_write(tmp_path, "shot.png"))
