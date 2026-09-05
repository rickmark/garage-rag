#!/usr/bin/env bash
set -euo pipefail

# Compute auto-incrementing build number using git commit count (main branch height)
BUILD_NUMBER=""
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Use commit count of HEAD (which corresponds to main branch height when on main)
    BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || true)
    if [ -z "$BUILD_NUMBER" ] || [ "$BUILD_NUMBER" -le 0 ] 2>/dev/null; then
        if git rev-parse --verify main >/dev/null 2>&1; then
            BUILD_NUMBER=$(git rev-list --count main 2>/dev/null || true)
        elif git rev-parse --verify origin/main >/dev/null 2>&1; then
            BUILD_NUMBER=$(git rev-list --count origin/main 2>/dev/null || true)
        fi
    fi
fi

if [ -z "$BUILD_NUMBER" ] || [ "$BUILD_NUMBER" -le 0 ] 2>/dev/null; then
    BUILD_NUMBER="1"
fi

echo "STABLE_BUILD_NUMBER ${BUILD_NUMBER}"
echo "BUILD_EMBED_LABEL ${BUILD_NUMBER}"
