#!/usr/bin/env bash
# Builds Postgres + pgvector from source into macapp/build/pg-install, with a
# vanilla (relocatable) directory layout — no Homebrew --libdir/--sharedir
# customization. See vendor-postgres.sh for why this is necessary.
#
# Deliberately built without SSL/ICU/readline/perl/python/tcl: this Postgres
# only ever talks to 127.0.0.1 from garage's own CLI, so none of those add
# anything, and skipping them means the result depends on nothing but macOS
# system libraries (libSystem, libz) — zero Homebrew paths to vendor or
# rpath-fix later.
set -euo pipefail

PG_VERSION="18.4"
PGVECTOR_VERSION="0.8.3"

MACAPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$MACAPP_DIR/build"
INSTALL_DIR="$BUILD_DIR/pg-install"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -d "postgresql-$PG_VERSION" ]; then
    echo "==> downloading postgresql-$PG_VERSION"
    curl -sS -o "postgresql-$PG_VERSION.tar.bz2" \
        "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2"
    tar xjf "postgresql-$PG_VERSION.tar.bz2"
fi

if [ ! -d "pgvector-$PGVECTOR_VERSION" ]; then
    echo "==> downloading pgvector-$PGVECTOR_VERSION"
    curl -sS -L -o "pgvector.tar.gz" \
        "https://github.com/pgvector/pgvector/archive/refs/tags/v$PGVECTOR_VERSION.tar.gz"
    tar xzf "pgvector.tar.gz"
fi

rm -rf "$INSTALL_DIR"

echo "==> configuring postgres"
(
    cd "postgresql-$PG_VERSION"
    ./configure \
        --prefix="$INSTALL_DIR" \
        --without-icu \
        --without-openssl \
        --without-readline \
        --without-perl \
        --without-python \
        --without-tcl \
        > "$BUILD_DIR/configure.log" 2>&1
)

echo "==> building postgres ($JOBS jobs)"
make -C "postgresql-$PG_VERSION" -j"$JOBS" > "$BUILD_DIR/make.log" 2>&1
echo "==> installing postgres"
make -C "postgresql-$PG_VERSION" install > "$BUILD_DIR/make-install.log" 2>&1

# Not built by `make install` at the top level: pg_trgm is a contrib module,
# and 001_extensions.sql (garage init-db) requires it.
echo "==> building contrib/pg_trgm"
make -C "postgresql-$PG_VERSION/contrib/pg_trgm" install >> "$BUILD_DIR/make-install.log" 2>&1

echo "==> building pgvector against $INSTALL_DIR/bin/pg_config"
make -C "pgvector-$PGVECTOR_VERSION" PG_CONFIG="$INSTALL_DIR/bin/pg_config" -j"$JOBS" \
    > "$BUILD_DIR/pgvector-make.log" 2>&1
make -C "pgvector-$PGVECTOR_VERSION" PG_CONFIG="$INSTALL_DIR/bin/pg_config" install \
    > "$BUILD_DIR/pgvector-install.log" 2>&1

echo "==> build complete: $INSTALL_DIR"
