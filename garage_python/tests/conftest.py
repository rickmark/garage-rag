"""Load the native libraries PythonXPCService.framework loads in the app.

In the app, dyld has loaded libpq and libtesseract before Python starts, and
garage_rag finds them among the process's images (garage_rag.native). On macOS
Bazel hands the tests the same builds through these test-only variables; loading
them here, before any test imports garage_rag, puts them where it looks.
"""

from __future__ import annotations

import ctypes
import os

for _variable in ("GARAGE_TEST_LIBPQ", "GARAGE_TEST_LIBTESSERACT"):
    _path = os.environ.get(_variable)
    if _path:
        ctypes.CDLL(os.path.abspath(_path), mode=ctypes.RTLD_GLOBAL)
