#!/usr/bin/env bash
# Freezes the `garage` CLI and `garage-mcp` server from ~/garage's uv venv
# into standalone onedir bundles under macapp/Resources/python-dist, so the
# packaged app needs no system Python/uv at all.
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$MACAPP_DIR/.." && pwd)"
VENV="$REPO_ROOT/.venv"
DIST="$MACAPP_DIR/Resources/python-dist"
WORK="$MACAPP_DIR/build/pyinstaller-work"
SPEC="$MACAPP_DIR/build/pyinstaller-spec"

if [ ! -x "$VENV/bin/python" ]; then
    echo "error: $VENV not found. In $REPO_ROOT: uv venv --python 3.14 && uv pip install -e '.[dev]'" >&2
    exit 1
fi

if ! "$VENV/bin/python" -m pyinstaller --version >/dev/null 2>&1; then
    echo "==> installing pyinstaller into $VENV"
    uv pip install --python "$VENV/bin/python" pyinstaller
fi

rm -rf "$DIST" "$WORK" "$SPEC"
mkdir -p "$DIST"

# Packages whose import graph PyInstaller's static analysis tends to miss
# (C extensions selected at runtime, plugin-style registration, dialect
# lookups by string). Over-including here costs disk, not correctness.
COLLECT_ALL=(
    psycopg
    pgvector
    sqlalchemy
    langchain_text_splitters
    pydantic
    pydantic_settings
    mcp
    rich
    typer
)
COLLECT_ARGS=()
for pkg in "${COLLECT_ALL[@]}"; do
    COLLECT_ARGS+=(--collect-all "$pkg")
done

COMMON_ARGS=(
    --noconfirm
    --clean
    --workpath "$WORK"
    --specpath "$SPEC"
    --distpath "$DIST"
    --paths "$REPO_ROOT/src"
    --add-data "$REPO_ROOT/sql:sql"
    "${COLLECT_ARGS[@]}"
)

mkdir -p "$WORK"

# cli.py uses relative imports (`from .config import ...`), so it must be run
# as part of the garage_rag package, not handed to PyInstaller directly as a
# top-level script (that made an earlier attempt fail with "attempted
# relative import with no known parent package"). A shim that imports it
# properly fixes that for both entry points.
echo "==> freezing garage CLI"
CLI_SHIM="$WORK/garage_cli_entry.py"
cat > "$CLI_SHIM" <<'PY'
from garage_rag.cli import app

if __name__ == "__main__":
    app()
PY
"$VENV/bin/pyinstaller" "${COMMON_ARGS[@]}" \
    --name garage \
    "$CLI_SHIM"

GARAGE_MCP_SRC="$REPO_ROOT/src/garage_rag/mcp_server/server.py"
if [ -f "$GARAGE_MCP_SRC" ]; then
    echo "==> freezing garage-mcp"
    MCP_SHIM="$WORK/garage_mcp_entry.py"
    cat > "$MCP_SHIM" <<'PY'
from garage_rag.mcp_server.server import main

if __name__ == "__main__":
    main()
PY
    "$VENV/bin/pyinstaller" "${COMMON_ARGS[@]}" \
        --name garage-mcp \
        "$MCP_SHIM"
else
    echo "==> skipping garage-mcp: $GARAGE_MCP_SRC not found"
fi

echo "==> python-dist ready at $DIST ($(du -sh "$DIST" | cut -f1))"
