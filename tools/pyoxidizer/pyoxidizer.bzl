"""Bazel rules and macros for PyOxidizer."""

load(
    "//tools/pyoxidizer:defs.bzl",
    _apple_pyoxidizer_binary = "apple_pyoxidizer_binary",
    _pyoxidizer = "pyoxidizer",
    _pyoxidizer_binary = "pyoxidizer_binary",
    _pyoxidizer_build = "pyoxidizer_build",
    _pyoxidizer_run = "pyoxidizer_run",
    _uv_export_requirements = "uv_export_requirements",
)

pyoxidizer = _pyoxidizer
pyoxidizer_build = _pyoxidizer_build
pyoxidizer_run = _pyoxidizer_run
pyoxidizer_binary = _pyoxidizer_binary
apple_pyoxidizer_binary = _apple_pyoxidizer_binary
uv_export_requirements = _uv_export_requirements
