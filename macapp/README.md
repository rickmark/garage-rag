# GarageApp

A macOS menu bar + window app that wraps a private Postgres instance and the
`garage` CLI / `garage-mcp` server for the [garage-rag](../README.md) project.
Fully self-contained: no Homebrew or system Python required at runtime.

## Building

The app is built by Bazel (via the Aspect CLI, see the [repo README](../README.md)
and `CLAUDE.md` for the one-time `direnv allow` / `bazel run //tools:bazel_env`
setup). There is no `swift build` / `swift run` path for the app itself:
`Package.swift` in this directory only builds the client library targets
(`LlamaClient`, `ModelDownloadClient`, `IngestClient`, `MCPServerClient`) for
quick iteration, because `GarageApp` and the XPC services depend on
gRPC-Swift, SwiftProtobuf, PythonKit and the vendored Python / Postgres /
llama.cpp that only the Bazel build provides.

```bash
# Developer ID-signed app bundle (alias of //macapp/Sources/GarageApp:GarageApp)
aspect build //macapp:GarageApp          # or: aspect build //:macapp
open bazel-bin/macapp/Sources/GarageApp/GarageApp.app

# Xcode project for editing/debugging (rules_xcodeproj; includes the XPC services and tests)
aspect run //:xcodeproj
open macapp/Garage.xcodeproj

# Unit tests
aspect test //macapp/Tests/GarageAppUnitTests:GarageAppUnitTests
aspect test //macapp/Tests/LlamaClientTests:LlamaClientTests
aspect test //macapp/Tests/GarageAppUITests:GarageAppUITests

# Distribution: thinned + notarized apps and .pkg installers (Developer ID),
# or an App Store xcarchive
aspect build //:package                  # //macapp/package:package
aspect build //:installer                # //macapp/package:GarageInstaller (arm64 + x86_64 .pkg)
aspect run //:install                    # installs the arm64 .pkg locally
aspect build //macapp:xcarchive          # //macapp:GarageStore.xcarchive
aspect run //macapp:xcarchive_open       # copies the archive into Xcode's Archives folder and opens it

# Smoke test of the embedded Python runtime, exactly as the XPC services start it
aspect run //macapp/Sources/PythonXPCService:python_embed_smoke -- /path/to/Garage.app
```

What ends up in the bundle is declared in `Sources/GarageApp/BUILD.bazel`
(`macos_application(name = "GarageApp")`):

- `MacOS/garage` — the `garage` CLI, a Swift binary (`//macapp/Sources/GarageCLI:garage`)
  that embeds the bundled Python and runs `garage_rag`'s Typer app in-process.
- `Resources/postgres` — Postgres 18 + pgvector built from source (`//ext/postgres`,
  `//ext/pgvector`, vendored through `//macapp/externals:postgres_output`), with
  `libpq` in `Frameworks/`.
- `Resources/schema` — the SQL migrations, `Resources/postgresql.conf`, the model
  manifest and the config JSON schema.
- `Resources/site-python` — the Python site-packages (`//macapp/externals:site-python`)
  used by the CLI and every XPC service; the interpreter itself is the
  `Python.framework` from `//ext/python`.
- `Frameworks/PythonXPCService.framework` — the shared runtime for the six
  `XPCServices/*.xpc` helpers listed under `xpc_services`.

## Why Postgres is built from source

Homebrew's `postgresql@18` bakes absolute `/opt/homebrew/...` paths for its
share/lib directories directly into the binary. Postgres 18's new
`extension_control_path` GUC looks like it should let you override that at
runtime — it doesn't, in practice: `CREATE EXTENSION vector` still only finds
control files at the compiled-in Homebrew path, confirmed by testing.

A from-source build with no custom `--libdir`/`--sharedir` keeps `bin/`,
`lib/`, `lib/postgresql/`, and `share/postgresql/` as plain siblings, which
Postgres resolves relative to `argv[0]` at runtime. That's genuinely
relocatable — verified by building it, copying the tree to an unrelated path,
and running `CREATE EXTENSION vector` there with zero path overrides. The Bazel
build (`//ext/postgres`, a `rules_foreign_cc` `configure_make`) configures with
`--with-icu --with-readline --with-zlib --with-template=darwin --disable-rpath`
as a universal (arm64 + x86_64) binary; ICU, readline and zlib come from the
static libraries under `//ext`, so the result still depends on nothing but macOS
system libraries. The one thing left to fix up is `libpq.dylib`'s own hardcoded
install name for the client tools (`//macapp/externals:libpq`).

One more non-obvious thing found along the way: this build of `postgres`
fails to start with `FATAL: postmaster became multithreaded during startup`
unless `LC_ALL=C` is set in its environment (`PostgresService.swift` does
this). Locale initialization on this platform spins up threads before
postgres's fork-safety check runs.

## App architecture

- `PostgresService` — owns a private cluster in `~/Library/Application Support/GarageApp/pgdata`, port 14824, database `garage-rag`. On first initialization it generates a random Postgres superuser password, stores it in the macOS Keychain, and creates the cluster with SCRAM authentication.
- `GarageCLIService` — runs one-shot `garage <subcommand>` invocations (scan, add-source, register-model, sync, …) against that cluster, streaming output. Dedicated instances and log streams exist for the long-running `backfill` and `enrich-facts` runs so they never block ordinary commands.
- `IngestService` — runs ingestion through `GarageIngestXPCService` (an XPC helper that embeds Python and calls `garage_rag.ingest` directly), receiving live progress and log callbacks over the connection. Ingest does not go through the CLI.
- `GarageMCPService` — owns the loopback HTTP `garage-mcp` server at `http://127.0.0.1:8787/mcp`, hosted inside the `GarageMCPServerService` XPC helper; started after Postgres and stopped before it.
- `GarageGRPCService` — owns the `GarageService` gRPC backend (port 50051) hosted inside the `GarageXPCService` helper; the Search and Documents views talk to it over gRPC-Swift.
- `LlamaService` / `ModelDownloadService` — drive the `LlamaXPCService` and `ModelDownloadXPCService` helpers through the `LlamaClient` / `ModelDownloadClient` modules.
- `XPCServiceManager` — pings all six helpers, streams their logs into the app, runs their in-service self tests and can restart or terminate them.
- `AppDelegate` — keeps the app running in the menu bar after the window closes, and signals Postgres and every helper to stop on every quit path (Cmd+Q, Dock quit, menu item).
- Views: Status, Sources & Ingest, Models, Search, Documents, Logs, MCP Server. Sources
  provides manual ingestion and an optional persisted schedule that ingests all
  sources and then backfills every registered model. The Models view
  provides controls for Llama models and embedding models: it includes
  the known-model catalog and fills each selection's slug, dimensions,
  provider-side reference, and default provider. The provider can then be
  changed between Ollama and LM Studio; start the selected provider locally
  before backfilling embeddings. An LM Studio API token can be saved in the
  macOS Keychain from this view and is passed as `GARAGE_LMSTUDIO_API_TOKEN`
  to each `garage` command.

The app-managed HTTP MCP server has its own lifecycle and logs. Claude
Desktop/Code still spawn their own `garage-mcp` process over stdio when
registered via `garage mcp-install`; this allows both connection modes. The
app supplies the authenticated database URL as `GARAGE_DATABASE_URL` to every
`garage` command and XPC helper; registration writes the same environment
variable into the MCP entry so each spawned `garage-mcp` process connects to the
app-managed database.

The Status view also provides database reset, backup, and restore controls.
Backups are PostgreSQL custom-format dumps; restore replaces the private Garage
database, while reset recreates it empty.
