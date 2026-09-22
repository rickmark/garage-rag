"""py_test wrapper that always drives pytest and wires in shared config.

aspect_rules_py 2.x removed `pytest_main` from the generic `py_test` (which
just runs a file as a script, so a pytest module would import and exit 0
without collecting anything). `py_pytest_test` is the pytest driver; this
wrapper injects the `@pypi//pytest` dependency it requires, drops the `main`
that Gazelle sets, and attaches `garage_python/pyproject.toml` as data so
pytest's `[tool.pytest.ini_options]` (notably `filterwarnings`) lands in the
test's runfiles where rootdir discovery finds it.
"""

load("@aspect_rules_py//py:defs.bzl", _py_pytest_test = "py_pytest_test")

_PYTEST = "@pypi//pytest"
_PYPROJECT = "//garage_python:pyproject.toml"

def py_test(name, deps = [], data = [], **kwargs):
    """pytest-driven `py_test`; see the module docstring.

    Args:
        name: test target name (also its default `srcs` stem).
        deps: test dependencies; `@pypi//pytest` is added when absent.
        data: runtime files; `//garage_python:pyproject.toml` is added when absent.
        **kwargs: forwarded to `py_pytest_test`.
    """
    kwargs.pop("main", None)  # py_pytest_test provides its own entrypoint
    if _PYTEST not in deps:
        deps = deps + [_PYTEST]
    if _PYPROJECT not in data:
        data = data + [_PYPROJECT]
    _py_pytest_test(
        name = name,
        deps = deps,
        data = data,
        **kwargs
    )
