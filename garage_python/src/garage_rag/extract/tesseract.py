"""In-process Tesseract through its C API (``capi.h``), loaded with ctypes.

The CLI route (pytesseract) forks a ``tesseract`` process per image, writes the
image to a temp file for it, and reloads the language model every time. Here the
pixels Pillow already decoded go straight to ``TessBaseAPISetImage``, and each
thread keeps one initialised engine, so the model loads once.

The library is found, in order, at ``GARAGE_LIBTESSERACT_PATH`` (GarageApp's
Python runtime exports its bundled ``Contents/Frameworks/libtesseract.dylib``),
the usual Homebrew locations, then the dynamic linker's search. Language data
comes from ``TESSDATA_PREFIX`` when set (the app exports its bundled
``Resources/tesseract/tessdata``), else the library's compiled-in default.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import threading
from dataclasses import dataclass

from PIL import Image

LIBRARY_ENV = "GARAGE_LIBTESSERACT_PATH"
TESSDATA_ENV = "TESSDATA_PREFIX"
LANGUAGE = "eng"

_HOMEBREW_CANDIDATES = (
    "/opt/homebrew/lib/libtesseract.dylib",
    "/usr/local/lib/libtesseract.dylib",
)

# TessPageIteratorLevel / TessPageSegMode values from publictypes.h.
_RIL_WORD = 3
# The CLI's default, and so what pytesseract used. TessBaseAPI itself defaults to
# PSM_SINGLE_BLOCK, which reads a multi-column screenshot as one run of text.
_PSM_AUTO = 3
# Below this, Tesseract ignores a stated resolution and estimates its own.
_MIN_CREDIBLE_DPI = 70


class TesseractUnavailable(RuntimeError):
    """libtesseract, or its language data, could not be loaded."""


@dataclass(frozen=True)
class Word:
    text: str
    confidence: float


def _find_library() -> str:
    explicit = os.environ.get(LIBRARY_ENV)
    if explicit:
        return explicit
    for candidate in _HOMEBREW_CANDIDATES:
        if os.path.exists(candidate):
            return candidate
    found = ctypes.util.find_library("tesseract")
    if found:
        return found
    raise TesseractUnavailable(
        f"libtesseract not found (set {LIBRARY_ENV}, or install tesseract so it is on the linker's search path)"
    )


_lib_lock = threading.Lock()
_lib: ctypes.CDLL | None = None


def _library() -> ctypes.CDLL:
    global _lib
    with _lib_lock:
        if _lib is not None:
            return _lib
        path = _find_library()
        # A libtesseract built with OpenMP (Homebrew's may be) threads internally,
        # which inside a process pool oversubscribes the CPU. The bundled one has none.
        os.environ.setdefault("OMP_THREAD_LIMIT", "1")
        try:
            lib = ctypes.CDLL(path)
        except OSError as exc:
            raise TesseractUnavailable(f"cannot load libtesseract at {path}: {exc}") from exc

        handle = ctypes.c_void_p
        lib.TessVersion.restype = ctypes.c_char_p
        lib.TessBaseAPICreate.restype = handle
        lib.TessBaseAPIDelete.argtypes = [handle]
        lib.TessBaseAPIInit3.argtypes = [handle, ctypes.c_char_p, ctypes.c_char_p]
        lib.TessBaseAPIInit3.restype = ctypes.c_int
        lib.TessBaseAPISetVariable.argtypes = [handle, ctypes.c_char_p, ctypes.c_char_p]
        lib.TessBaseAPISetVariable.restype = ctypes.c_int
        lib.TessBaseAPISetPageSegMode.argtypes = [handle, ctypes.c_int]
        lib.TessBaseAPISetImage.argtypes = [
            handle,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
        ]
        lib.TessBaseAPISetSourceResolution.argtypes = [handle, ctypes.c_int]
        lib.TessBaseAPIRecognize.argtypes = [handle, ctypes.c_void_p]
        lib.TessBaseAPIRecognize.restype = ctypes.c_int
        lib.TessBaseAPIGetIterator.argtypes = [handle]
        lib.TessBaseAPIGetIterator.restype = handle
        lib.TessBaseAPIClear.argtypes = [handle]
        lib.TessResultIteratorDelete.argtypes = [handle]
        lib.TessResultIteratorNext.argtypes = [handle, ctypes.c_int]
        lib.TessResultIteratorNext.restype = ctypes.c_int
        lib.TessResultIteratorConfidence.argtypes = [handle, ctypes.c_int]
        lib.TessResultIteratorConfidence.restype = ctypes.c_float
        # A char* the caller must hand back to TessDeleteText, so not c_char_p
        # (ctypes would copy it and drop the pointer).
        lib.TessResultIteratorGetUTF8Text.argtypes = [handle, ctypes.c_int]
        lib.TessResultIteratorGetUTF8Text.restype = ctypes.POINTER(ctypes.c_char)
        lib.TessDeleteText.argtypes = [ctypes.POINTER(ctypes.c_char)]
        _lib = lib
        return lib


def version() -> str:
    return _library().TessVersion().decode()


class _Engine:
    """One initialised TessBaseAPI. Not thread-safe; see :func:`_engine`."""

    def __init__(self) -> None:
        self.lib = _library()
        self.api = self.lib.TessBaseAPICreate()
        datapath = os.environ.get(TESSDATA_ENV)
        rc = self.lib.TessBaseAPIInit3(self.api, datapath.encode() if datapath else None, LANGUAGE.encode())
        if rc != 0:
            self.lib.TessBaseAPIDelete(self.api)
            where = datapath or "the library's default tessdata"
            raise TesseractUnavailable(f"tesseract could not load '{LANGUAGE}' language data from {where}")
        self.lib.TessBaseAPISetPageSegMode(self.api, _PSM_AUTO)
        # tprintf goes to stderr otherwise ("Estimating resolution as ..." per image).
        self.lib.TessBaseAPISetVariable(self.api, b"debug_file", b"/dev/null")

    def __del__(self) -> None:
        api = getattr(self, "api", None)
        if api:
            self.lib.TessBaseAPIDelete(api)

    def words(self, image: Image.Image) -> list[Word]:
        lib, api = self.lib, self.api
        pixels = image.tobytes()
        bpp = len(image.getbands())
        lib.TessBaseAPISetImage(api, pixels, image.width, image.height, bpp, image.width * bpp)
        dpi = image.info.get("dpi")
        if dpi and int(dpi[0]) >= _MIN_CREDIBLE_DPI:
            lib.TessBaseAPISetSourceResolution(api, int(dpi[0]))
        try:
            if lib.TessBaseAPIRecognize(api, None) != 0:
                raise RuntimeError("tesseract recognition failed")
            iterator = lib.TessBaseAPIGetIterator(api)
            if not iterator:
                return []
            words: list[Word] = []
            try:
                while True:
                    raw = lib.TessResultIteratorGetUTF8Text(iterator, _RIL_WORD)
                    if raw:
                        text = ctypes.string_at(raw).decode("utf-8", errors="replace")
                        lib.TessDeleteText(raw)
                        words.append(Word(text, float(lib.TessResultIteratorConfidence(iterator, _RIL_WORD))))
                    if not lib.TessResultIteratorNext(iterator, _RIL_WORD):
                        break
            finally:
                lib.TessResultIteratorDelete(iterator)
            return words
        finally:
            lib.TessBaseAPIClear(api)


_local = threading.local()


def _engine() -> _Engine:
    engine = getattr(_local, "engine", None)
    if engine is None:
        engine = _Engine()
        _local.engine = engine
    return engine


def _pixels_for(image: Image.Image) -> Image.Image:
    """8-bit grey or RGB, the layouts SetImage takes; transparency goes onto white."""
    if image.mode in ("L", "RGB"):
        return image
    if "A" in image.getbands() or image.mode == "P" and "transparency" in image.info:
        rgba = image.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        return Image.alpha_composite(background, rgba).convert("RGB")
    return image.convert("L" if image.mode in ("1", "I", "I;16", "F") else "RGB")


def recognize(image: Image.Image) -> list[Word]:
    """Words Tesseract reads in ``image``, with their 0-100 confidences."""
    return _engine().words(_pixels_for(image))
