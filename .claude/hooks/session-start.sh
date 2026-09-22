#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# The container has no Swift toolchain and no populated Python venv, so without this
# neither `pytest`/`ruff` nor any Swift checking works in a web session. It:
#   1. creates garage_python/.venv with the package and its dev extras (pytest, ruff,
#      tree-sitter for tools/swiftcheck);
#   2. installs the swift.org Linux toolchain under /opt/swift so `swiftc -parse` and
#      `swift-format lint` can syntax-check macapp/ (type checking still needs macOS:
#      every module imports Apple-only frameworks). Needs download.swift.org allowed in
#      the environment's network policy; if the download fails the hook says so and the
#      tree-sitter checker remains the fallback.
# Idempotent: every step is skipped when its result already exists, and the container
# state is cached after the hook completes.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
ENV_FILE="${CLAUDE_ENV_FILE:-/dev/null}"
cd "$REPO"

log() { printf '[session-start] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Python: uv + the package venv with dev extras
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  log "installing uv"
  python3 -m pip install --quiet --user uv 2>/dev/null || pip install --quiet uv
  export PATH="$HOME/.local/bin:$PATH"
fi

VENV="$REPO/garage_python/.venv"
if [ ! -x "$VENV/bin/pytest" ] || [ ! -x "$VENV/bin/ruff" ]; then
  log "creating $VENV (python 3.13, package + dev extras)"
  uv venv --quiet --python 3.13 "$VENV"
fi
# uv.lock only resolves for macOS (pyproject [tool.uv].environments), so install the
# project directly instead of `uv sync`. No-op when everything is already present.
VIRTUAL_ENV="$VENV" uv pip install --quiet -e "$REPO/garage_python[dev]"
echo "export PATH=\"$VENV/bin:\$PATH\"" >> "$ENV_FILE"
log "python: $("$VENV/bin/python" --version), pytest $("$VENV/bin/pytest" --version 2>&1 | awk '{print $2}')"

# ---------------------------------------------------------------------------
# 2. Swift toolchain (syntax checking only on Linux)
# ---------------------------------------------------------------------------
SWIFT_VERSION="${GARAGE_SWIFT_VERSION:-6.1.2}"
SWIFT_HOME="${GARAGE_SWIFT_HOME:-/opt/swift}"
UBUNTU_VERSION="$(. /etc/os-release && echo "${VERSION_ID:-24.04}")"
UBUNTU_TAG="ubuntu${UBUNTU_VERSION}"
UBUNTU_DIR="$(echo "$UBUNTU_TAG" | tr -d .)"
ARCH_SUFFIX=""
case "$(uname -m)" in
  aarch64) ARCH_SUFFIX="-aarch64" ;;
esac
TARBALL="swift-${SWIFT_VERSION}-RELEASE-${UBUNTU_TAG}${ARCH_SUFFIX}.tar.gz"
URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${UBUNTU_DIR}${ARCH_SUFFIX}/swift-${SWIFT_VERSION}-RELEASE/${TARBALL}"

install_swift() {
  # The runtime libraries swiftc needs; most are already in the image. Non-fatal so a
  # sealed apt mirror does not take the whole hook down.
  if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      binutils libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev libsqlite3-0 \
      libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata zlib1g-dev >/dev/null 2>&1 \
      || log "apt-get could not install the toolchain's helper packages; continuing"
  fi
  local tmp
  tmp="$(mktemp -d)"
  log "downloading $URL"
  if ! curl -fsSL --retry 3 -o "$tmp/$TARBALL" "$URL"; then
    log "download failed (is download.swift.org allowed in this environment's network policy?)"
    rm -rf "$tmp"
    return 1
  fi
  if [ -n "${GARAGE_SWIFT_SHA256:-}" ]; then
    echo "${GARAGE_SWIFT_SHA256}  $tmp/$TARBALL" | sha256sum -c - >/dev/null || {
      log "checksum mismatch for $TARBALL"; rm -rf "$tmp"; return 1; }
  fi
  mkdir -p "$SWIFT_HOME"
  tar -xzf "$tmp/$TARBALL" -C "$SWIFT_HOME" --strip-components=1
  rm -rf "$tmp"
}

if [ ! -x "$SWIFT_HOME/usr/bin/swiftc" ]; then
  if ! install_swift; then
    log "Swift toolchain unavailable; tools/swiftcheck falls back to the tree-sitter checker"
  fi
fi

if [ -x "$SWIFT_HOME/usr/bin/swiftc" ]; then
  echo "export PATH=\"$SWIFT_HOME/usr/bin:\$PATH\"" >> "$ENV_FILE"
  log "swift: $("$SWIFT_HOME/usr/bin/swiftc" --version 2>&1 | head -1)"
fi

log "done"
