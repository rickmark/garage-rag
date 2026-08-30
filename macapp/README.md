# GarageApp

A macOS menu bar + window app that wraps a private Postgres instance and the
`garage` CLI / `garage-mcp` server for the [garage-rag](../../README.md) project.
Fully self-contained: no Homebrew or system Python required at runtime.

## Running in development

```bash
swift run
```

This uses the Homebrew `postgresql@18`/`pgvector` install and the repo's
`.venv` directly (see `Paths.swift`) — no vendoring step needed. Requires
both to already be set up per the [main README](../../README.md#install).

## Building the distributable .app

```bash
./Scripts/build-app.sh
```

First run takes a while: it builds Postgres 18 + pgvector from source (see
below for why) and freezes the `garage`/`garage-mcp` Python entry points with
PyInstaller, before assembling `dist/GarageApp.app`. Subsequent runs reuse
`build/pg-install` and `Resources/python-dist` unless you delete them.

Individual steps, if you need to re-run just one:

- `Scripts/build-postgres.sh` — compiles Postgres + pgvector from source into `build/pg-install`
- `Scripts/vendor-postgres.sh` — copies the relevant subset into `Resources/postgres`, fixing up libpq's install name
- `Scripts/build-python.sh` — PyInstaller-freezes `garage` and `garage-mcp` from `../../.venv` into `Resources/python-dist`

## Why Postgres is built from source

Homebrew's `postgresql@18` bakes absolute `/opt/homebrew/...` paths for its
share/lib directories directly into the binary. Postgres 18's new
`extension_control_path` GUC looks like it should let you override that at
runtime — it doesn't, in practice: `CREATE EXTENSION vector` still only finds
control files at the compiled-in Homebrew path, confirmed by testing.

A vanilla from-source build (`--without-icu --without-openssl --without-readline`,
no custom `--libdir`/`--sharedir`) keeps `bin/`, `lib/`, `lib/postgresql/`, and
`share/postgresql/` as plain siblings, which Postgres resolves relative to
`argv[0]` at runtime. That's genuinely relocatable — verified by building it,
copying the tree to an unrelated path, and running `CREATE EXTENSION vector`
there with zero path overrides. It also ends up depending on nothing but
macOS system libraries (`libSystem`, `libz`), so there's no third-party dylib
vendoring to do at all, beyond fixing up `libpq.dylib`'s own hardcoded
install name for the client tools.

One more non-obvious thing found along the way: this build of `postgres`
fails to start with `FATAL: postmaster became multithreaded during startup`
unless `LC_ALL=C` is set in its environment (`PostgresService.swift` does
this). Locale initialization on this platform spins up threads before
postgres's fork-safety check runs.

## App architecture

- `PostgresService` — owns a private cluster in `~/Library/Application Support/GarageApp/pgdata`, port 14824, database `garage-rag`. On first initialization it generates a random Postgres superuser password, stores it in the macOS Keychain, and creates the cluster with SCRAM authentication.
- `GarageCLIService` — runs `garage <subcommand>` one-shot invocations against that cluster, streaming output.
- `AppDelegate` — keeps the app running in the menu bar after the window closes, and signals Postgres to stop on every quit path (Cmd+Q, Dock quit, menu item).
- Views: Status, Sources & Ingest, Embedding Models, Search, Logs.

Claude Desktop/Code spawn `garage-mcp` themselves over stdio once registered
via `garage mcp-install` (wired up as a button under Status). The app supplies
the authenticated database URL as `GARAGE_DATABASE_URL` to every `garage`
command; registration writes the same environment variable into the MCP entry
so each spawned `garage-mcp` process connects to the app-managed database.

The Status view also provides database reset, backup, and restore controls.
Backups are PostgreSQL custom-format dumps; restore replaces the private Garage
database, while reset recreates it empty.
