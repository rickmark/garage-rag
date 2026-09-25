"""Decode images through macOS ImageIO, loaded with ctypes.

Pillow reads HEIC/HEIF only through a plugin built on libheif, whose wheels
bundle libde265 and x265: LGPL and GPL code, and HEVC patent licensing, that
the App Store build cannot carry. ImageIO is part of macOS, decodes HEIC with
the system's own (licensed) HEVC decoder, and is reachable from every process
the app runs, sandboxed or not, with no entitlement. So images Pillow cannot
open go through here, and the result is handed to OCR as a Pillow image.

The image is decoded the way the Photos app shows it: EXIF/HEIF orientation is
applied (Tesseract reads a rotated page poorly), and transparent pixels are laid
over white.
"""

from __future__ import annotations

import ctypes
import sys
import threading
from pathlib import Path

from garage_rag.extract.base import ExtractionError

_FRAMEWORKS = "/System/Library/Frameworks"

# CFNumberType / CGImageAlphaInfo values from CFNumber.h and CGImage.h.
_CF_NUMBER_SINT64 = 4
_CG_IMAGE_ALPHA_NONE_SKIP_LAST = 5


class _CGRect(ctypes.Structure):
    # CGFloat is a double on every 64-bit Mac.
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("width", ctypes.c_double), ("height", ctypes.c_double)]


class _Frameworks:
    def __init__(self) -> None:
        self.cf = ctypes.CDLL(f"{_FRAMEWORKS}/CoreFoundation.framework/CoreFoundation")
        self.cg = ctypes.CDLL(f"{_FRAMEWORKS}/CoreGraphics.framework/CoreGraphics")
        self.io = ctypes.CDLL(f"{_FRAMEWORKS}/ImageIO.framework/ImageIO")
        ref = ctypes.c_void_p
        cf, cg, io = self.cf, self.cg, self.io

        cf.CFRelease.argtypes = [ref]
        cf.CFRelease.restype = None
        cf.CFURLCreateFromFileSystemRepresentation.argtypes = [ref, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
        cf.CFURLCreateFromFileSystemRepresentation.restype = ref
        cf.CFDictionaryGetValue.argtypes = [ref, ref]
        cf.CFDictionaryGetValue.restype = ref
        cf.CFDictionaryCreate.argtypes = [
            ref,
            ctypes.POINTER(ref),
            ctypes.POINTER(ref),
            ctypes.c_long,
            ref,
            ref,
        ]
        cf.CFDictionaryCreate.restype = ref
        cf.CFNumberCreate.argtypes = [ref, ctypes.c_long, ref]
        cf.CFNumberCreate.restype = ref
        cf.CFNumberGetValue.argtypes = [ref, ctypes.c_long, ref]
        cf.CFNumberGetValue.restype = ctypes.c_bool

        io.CGImageSourceCreateWithURL.argtypes = [ref, ref]
        io.CGImageSourceCreateWithURL.restype = ref
        io.CGImageSourceGetCount.argtypes = [ref]
        io.CGImageSourceGetCount.restype = ctypes.c_size_t
        io.CGImageSourceCopyPropertiesAtIndex.argtypes = [ref, ctypes.c_size_t, ref]
        io.CGImageSourceCopyPropertiesAtIndex.restype = ref
        io.CGImageSourceCreateThumbnailAtIndex.argtypes = [ref, ctypes.c_size_t, ref]
        io.CGImageSourceCreateThumbnailAtIndex.restype = ref

        cg.CGImageGetWidth.argtypes = [ref]
        cg.CGImageGetWidth.restype = ctypes.c_size_t
        cg.CGImageGetHeight.argtypes = [ref]
        cg.CGImageGetHeight.restype = ctypes.c_size_t
        cg.CGColorSpaceCreateDeviceRGB.argtypes = []
        cg.CGColorSpaceCreateDeviceRGB.restype = ref
        cg.CGBitmapContextCreate.argtypes = [
            ref,
            ctypes.c_size_t,
            ctypes.c_size_t,
            ctypes.c_size_t,
            ctypes.c_size_t,
            ref,
            ctypes.c_uint32,
        ]
        cg.CGBitmapContextCreate.restype = ref
        cg.CGContextSetRGBFillColor.argtypes = [ref, ctypes.c_double, ctypes.c_double, ctypes.c_double, ctypes.c_double]
        cg.CGContextSetRGBFillColor.restype = None
        cg.CGContextFillRect.argtypes = [ref, _CGRect]
        cg.CGContextFillRect.restype = None
        cg.CGContextDrawImage.argtypes = [ref, _CGRect, ref]
        cg.CGContextDrawImage.restype = None

        def constant(lib: ctypes.CDLL, name: str) -> ctypes.c_void_p:
            return ctypes.c_void_p.in_dll(lib, name)

        self.true = constant(cf, "kCFBooleanTrue")
        # The callback structs are passed by address, not by value.
        self.key_callbacks = ctypes.addressof(ctypes.c_byte.in_dll(cf, "kCFTypeDictionaryKeyCallBacks"))
        self.value_callbacks = ctypes.addressof(ctypes.c_byte.in_dll(cf, "kCFTypeDictionaryValueCallBacks"))
        self.pixel_width = constant(io, "kCGImagePropertyPixelWidth")
        self.pixel_height = constant(io, "kCGImagePropertyPixelHeight")
        self.from_image_always = constant(io, "kCGImageSourceCreateThumbnailFromImageAlways")
        self.with_transform = constant(io, "kCGImageSourceCreateThumbnailWithTransform")
        self.max_pixel_size = constant(io, "kCGImageSourceThumbnailMaxPixelSize")


_lock = threading.Lock()
_frameworks: _Frameworks | None = None


def available() -> bool:
    return sys.platform == "darwin"


def _load() -> _Frameworks:
    global _frameworks
    if not available():
        raise ExtractionError("decoding this image needs macOS ImageIO")
    with _lock:
        if _frameworks is None:
            try:
                _frameworks = _Frameworks()
            except (OSError, ValueError) as exc:
                raise ExtractionError(f"ImageIO unavailable: {exc}") from exc
        return _frameworks


def _number(fw: _Frameworks, dictionary: int, key: ctypes.c_void_p) -> int | None:
    value = fw.cf.CFDictionaryGetValue(dictionary, key)
    if not value:
        return None
    out = ctypes.c_int64()
    if not fw.cf.CFNumberGetValue(value, _CF_NUMBER_SINT64, ctypes.byref(out)):
        return None
    return out.value


def open_image(path: Path, *, max_pixels: int):
    """Decode ``path``'s first image into an RGB Pillow image, oriented for display.

    Raises :class:`ExtractionError` for a file ImageIO cannot read, or one larger
    than ``max_pixels`` (checked from the header, before anything is decoded).
    """
    from PIL import Image

    fw = _load()
    cf, cg, io = fw.cf, fw.cg, fw.io
    owned: list[int] = []
    try:
        encoded = str(path).encode()
        url = cf.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), False)
        if not url:
            raise ExtractionError(f"unreadable image {path}: bad path")
        owned.append(url)
        source = io.CGImageSourceCreateWithURL(url, None)
        if not source:
            raise ExtractionError(f"unreadable image {path}: ImageIO cannot open it")
        owned.append(source)
        if io.CGImageSourceGetCount(source) < 1:
            raise ExtractionError(f"unreadable image {path}: no image in the file")

        properties = io.CGImageSourceCopyPropertiesAtIndex(source, 0, None)
        if not properties:
            raise ExtractionError(f"unreadable image {path}: ImageIO found no image properties")
        owned.append(properties)
        width = _number(fw, properties, fw.pixel_width)
        height = _number(fw, properties, fw.pixel_height)
        if not width or not height:
            raise ExtractionError(f"unreadable image {path}: no pixel size")
        if width * height > max_pixels:
            raise ExtractionError(f"image too large to OCR ({width}x{height}): {path}")

        # A "thumbnail" as large as the image itself is ImageIO's documented way to
        # get the pixels with the orientation applied.
        longest = ctypes.c_int64(max(width, height))
        size = cf.CFNumberCreate(None, _CF_NUMBER_SINT64, ctypes.byref(longest))
        owned.append(size)
        keys = (ctypes.c_void_p * 3)(fw.from_image_always, fw.with_transform, fw.max_pixel_size)
        values = (ctypes.c_void_p * 3)(fw.true, fw.true, size)
        options = cf.CFDictionaryCreate(None, keys, values, 3, fw.key_callbacks, fw.value_callbacks)
        owned.append(options)
        image = io.CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        if not image:
            raise ExtractionError(f"unreadable image {path}: ImageIO could not decode it")
        owned.append(image)

        width, height = cg.CGImageGetWidth(image), cg.CGImageGetHeight(image)
        stride = width * 4
        pixels = ctypes.create_string_buffer(stride * height)
        space = cg.CGColorSpaceCreateDeviceRGB()
        owned.append(space)
        context = cg.CGBitmapContextCreate(pixels, width, height, 8, stride, space, _CG_IMAGE_ALPHA_NONE_SKIP_LAST)
        if not context:
            raise ExtractionError(f"unreadable image {path}: could not allocate {width}x{height} pixels")
        owned.append(context)
        rect = _CGRect(0, 0, width, height)
        cg.CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0)
        cg.CGContextFillRect(context, rect)
        cg.CGContextDrawImage(context, rect, image)

        return Image.frombuffer("RGBX", (width, height), pixels.raw, "raw", "RGBX", stride, 1).convert("RGB")
    finally:
        for ref in reversed(owned):
            cf.CFRelease(ref)
