"""The local OCR pass: which tesseract it runs and what image it hands over."""

from __future__ import annotations

from pathlib import Path

import pytest
import pytesseract
from PIL import Image

from garage_rag.extract import image as image_extract


@pytest.fixture
def captured(monkeypatch):
    """Replaces pytesseract.image_to_data, recording the image it was given."""
    seen: dict[str, object] = {}

    def fake_image_to_data(img, output_type=None):
        seen["format"] = img.format
        seen["mode"] = img.mode
        seen["cmd"] = pytesseract.pytesseract.tesseract_cmd
        return {"text": ["Hello", "", "world"], "conf": ["90", "-1", "80"]}

    monkeypatch.setattr(pytesseract, "image_to_data", fake_image_to_data)
    monkeypatch.setattr(pytesseract.pytesseract, "tesseract_cmd", "tesseract")
    return seen


def _write(tmp_path: Path, name: str, fmt: str, mode: str = "RGB") -> Path:
    path = tmp_path / name
    Image.new(mode, (400, 300), "white").save(path, format=fmt)
    return path


def test_bundled_tesseract_is_used_when_exported(monkeypatch, tmp_path, captured):
    monkeypatch.setenv("GARAGE_TESSERACT_CMD", "/Applications/Garage.app/Contents/Resources/tesseract/bin/tesseract")
    text, confidence = image_extract._tesseract(_write(tmp_path, "shot.png", "PNG"))

    assert captured["cmd"] == "/Applications/Garage.app/Contents/Resources/tesseract/bin/tesseract"
    assert text == "Hello world"
    assert confidence == pytest.approx(85.0)


def test_path_lookup_is_left_alone_without_the_variable(monkeypatch, tmp_path, captured):
    monkeypatch.delenv("GARAGE_TESSERACT_CMD", raising=False)
    image_extract._tesseract(_write(tmp_path, "shot.png", "PNG"))

    assert captured["cmd"] == "tesseract"


@pytest.mark.parametrize(
    ("name", "fmt", "mode"),
    [("photo.jpg", "JPEG", "RGB"), ("anim.gif", "GIF", "P"), ("shot.png", "PNG", "RGB")],
)
def test_tesseract_is_always_handed_a_png(monkeypatch, tmp_path, captured, name, fmt, mode):
    # pytesseract saves a format-less image as PNG, the only codec the bundled
    # Leptonica is built with.
    monkeypatch.delenv("GARAGE_TESSERACT_CMD", raising=False)
    image_extract._tesseract(_write(tmp_path, name, fmt, mode))

    assert captured["format"] is None
    assert captured["mode"] in {"1", "L", "RGB", "RGBA"}
