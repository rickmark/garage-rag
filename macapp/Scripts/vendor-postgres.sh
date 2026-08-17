#!/usr/bin/env bash
# Vendors a self-contained Postgres + pgvector into macapp/Resources/postgres.
#
# This does NOT use the Homebrew postgresql@18/pgvector install. Homebrew
# builds bake absolute /opt/homebrew/... paths for sharedir/pkglibdir into the
# binaries themselves (confirmed by testing: Postgres 18's extension_control_path
# GUC does not override primary control-file discovery for that build), so a
# Homebrew binary cannot be relocated into an app bundle and still find
# pgvector. Instead, build-postgres.sh below produces a *vanilla* from-source
# build with no --libdir/--sharedir customization, which keeps bin/, lib/,
# lib/postgresql/, and share/postgresql/ as plain siblings under one prefix.
# Postgres resolves those relative to argv[0] at runtime (make_relative_path),
# so the whole tree is genuinely relocatable — verified by building it,
# copying it to an unrelated path, and running CREATE EXTENSION vector there
# with zero path overrides.
#
# The only thing that ISN'T relocatable out of the box is the client tools'
# hardcoded absolute reference to libpq.dylib (install_name bakes in the build
# path), fixed up below with install_name_tool.
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$MACAPP_DIR/build"
INSTALL_DIR="$BUILD_DIR/pg-install"
DEST="$MACAPP_DIR/Resources/postgres"

PG_VERSION="18.4"
PGVECTOR_VERSION="0.8.3"

if [ ! -x "$INSTALL_DIR/bin/postgres" ]; then
    echo "==> no local build at $INSTALL_DIR; building Postgres $PG_VERSION + pgvector $PGVECTOR_VERSION from source"
    "$(dirname "${BASH_SOURCE[0]}")/build-postgres.sh"
fi

echo "==> vendoring into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/lib/postgresql" "$DEST/share/postgresql/extension"

# Only the tools the app actually shells out to (PostgresService.swift /
# GarageCLIService.swift). Anything else in the from-source build (pg_dump,
# pg_basebackup, ecpg, the whole pgxs/ build-extension toolchain, headers,
# regress binaries, ...) is build tooling we don't ship.
BIN_TOOLS=(postgres initdb pg_ctl pg_isready psql createdb dropdb)
for tool in "${BIN_TOOLS[@]}"; do
    cp "$INSTALL_DIR/bin/$tool" "$DEST/bin/$tool"
done

cp -a "$INSTALL_DIR"/lib/libpq*.dylib "$DEST/lib/"

# The whole pkglibdir, not just vector/pg_trgm: initdb's bootstrap script
# unconditionally needs plpgsql, dict_snowball, and the encoding-conversion
# modules (euc_jp_and_sjis.dylib etc), so cherry-picking breaks initdb on
# non-ASCII/CJK-adjacent default configs. It's all of a few hundred KB total.
cp -R "$INSTALL_DIR/lib/postgresql/." "$DEST/lib/postgresql/"
rm -rf "$DEST/lib/postgresql/pgxs"
# Streaming-replication only (this app runs a single standalone node); it also
# links libpq at a hardcoded build-machine path, which isn't worth fixing up
# for a module we never load.
rm -f "$DEST/lib/postgresql/libpqwalreceiver.dylib"

# Full sharedir: initdb needs postgres.bki, system_views.sql, timezone data,
# etc, not just the extension subdir.
cp -R "$INSTALL_DIR/share/postgresql/." "$DEST/share/postgresql/"

echo "==> rewriting libpq install names (build path -> @rpath)"
# libpq.<major>.<minor>.dylib is the real file; libpq.5.dylib and libpq.dylib
# are symlinks to it — find the non-symlink explicitly rather than guessing
# the version number.
LIBPQ_REAL="$(cd "$DEST/lib" && for f in libpq.*.dylib; do [ -L "$f" ] || echo "$f"; done | head -1)"

install_name_tool -id "@rpath/$LIBPQ_REAL" "$DEST/lib/$LIBPQ_REAL"
for f in "$DEST"/bin/*; do
    if otool -L "$f" | grep -q "libpq"; then
        install_name_tool -change "$INSTALL_DIR/lib/$LIBPQ_REAL" "@rpath/$LIBPQ_REAL" "$f" 2>/dev/null || true
        install_name_tool -add_rpath "@executable_path/../lib" "$f" 2>/dev/null || true
    fi
done

echo "==> verifying no build-machine paths remain"
if otool -L "$DEST"/bin/* "$DEST"/lib/*.dylib "$DEST"/lib/postgresql/*.dylib 2>/dev/null | grep -E "$BUILD_DIR|/opt/homebrew"; then
    echo "error: found un-rewritten build/homebrew paths above" >&2
    exit 1
fi

echo "==> vendored postgres tree ready at $DEST ($(du -sh "$DEST" | cut -f1))"
