# GarageApp

A macOS menu bar + window app that wraps a private Postgres instance and the
`garage` CLI / `garage-mcp` server for the [garage-rag](../README.md) project.
Fully self-contained: no Homebrew or system Python required at runtime.

## Building

The app is built by Bazel (via the Aspect CLI, see the [repo README](../README.md)
and `CLAUDE.md` for the one-time `direnv allow` / `bazel run //tools:bazel_env`
setup). There is no SwiftPM manifest and no `swift build` / `swift run` path:
every module, the client libraries included, depends on `PythonXPCService`,
which in turn needs PythonKit, the CPython embedding shim and the vendored
Python / Postgres / llama.cpp that only the Bazel build provides. For an IDE
loop, generate the Xcode project (`aspect run //:xcodeproj`), which carries
the app, every XPC service and all three test bundles.

```bash
# Ad-hoc signed app bundle (alias of //macapp/Sources/GarageApp:GarageApp)
aspect build //macapp:GarageApp          # or: aspect build //:macapp
aspect run //:macapp                     # builds, then launches it

# The build output is a .zip, not a loose bundle; `aspect run` unpacks and
# launches it for you. To open it by hand:
unzip -q -o bazel-bin/macapp/Sources/GarageApp/GarageApp.zip -d /tmp/garage && open /tmp/garage/Garage.app

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
aspect build //:installer                # //macapp/package:GarageInstaller (arm64 .pkg)
aspect run //:install                    # installs the .pkg locally
aspect build //macapp:xcarchive          # //macapp:GarageStore.xcarchive
aspect run //macapp:xcarchive_open       # copies the archive into Xcode's Archives folder and opens it

# Smoke test of the embedded Python runtime, exactly as the XPC services start it
aspect run //macapp/Sources/PythonXPCService:python_embed_smoke -- /path/to/Garage.app
```

What ends up in the bundle is declared in `Sources/GarageApp/BUILD.bazel`
(`macos_application(name = "GarageApp")`):

- `MacOS/garage` and `MacOS/garage-mcp` — Swift launchers (`//macapp/Sources/GarageCLI:garage`,
  `//macapp/Sources/GarageMCPCLI:garage-mcp`, sharing `Sources/GarageLauncher`) that embed the
  bundled Python and run `garage_rag`'s Typer app or the stdio MCP server in-process. When a
  command needs the database and nothing listens on port 14824, the launcher opens Garage.app
  hidden (`--background`: services start, no window) and waits for Postgres; it then reads the
  database password from the Keychain and exports `GARAGE_DATABASE_URL` itself. An explicit
  `GARAGE_DATABASE_URL` wins; `GARAGE_NO_APP_LAUNCH=1` fails instead of opening the app.
  `garage-mcp` does not wait for Postgres (only its tool calls use the database, and the MCP
  handshake must not sit behind a cold start) unless the app has never stored a password, and
  never mirrors its stdout (the MCP stream) into the unified log.
- `Resources/postgres` — Postgres 18 + pgvector built from source (`//ext/postgres`,
  `//ext/pgvector`, vendored through `//macapp/externals:postgres_output`), with
  `libpq` in `Frameworks/`.
- `Resources/schema` — the SQL migrations, `Resources/postgresql.conf`, the model
  manifest and the config JSON schema.
- `Frameworks/PythonXPCService.framework` — the shared runtime for the six
  `XPCServices/*.xpc` helpers listed under `xpc_services`. Its resources hold
  `site-python` (`//macapp/externals:site-python`): the standard library,
  `lib-dynload` and site-packages, used by the CLI and every XPC service. It lives
  in the framework because a sandboxed XPC service may read inside the frameworks it
  links but not elsewhere in the app bundle. The interpreter itself is the
  `Python.framework` from `//ext/python`, kept to the bare interpreter.
- The four Python XPC services also link `Frameworks/libpq.dylib` at load time, so it
  is mapped before the App Sandbox applies; opening it later by path is denied.

## A stable local signing identity

The app keeps two secrets in the macOS Keychain — the Postgres superuser
password (`PostgresService`) and the LM Studio API token (`LMStudioTokenStore`)
— and a Keychain item's ACL names the application by its *designated
requirement*. For an ad-hoc signature that requirement is

```
identifier "me.rickmark.garage-rag" and cdhash H"<hash of this exact build>"
```

which a rebuild invalidates, because the cdhash is a hash of the build. That is
the "GarageApp wants to access key ..." dialog on every build, and why a build
can find the cluster it initialized yesterday but not the password to it.

Signing with a certificate anchors the requirement to the certificate instead:

```
identifier "me.rickmark.garage-rag" and certificate root = H"<hash of the cert>"
```

which no rebuild changes. `//tools/signing:local_identity` generates a
self-signed certificate for that and nothing else:

```bash
bazel run //tools/signing:local_identity          # create it (asks for your password)
bazel run //tools/signing:local_identity -- show  # what it is, and the requirement it yields
```

Then build against it by putting this in `user.bazelrc` (git-ignored):

```
build --config=local_signed
```

Things worth knowing:

- Answer **Always Allow** the first time macOS asks whether `codesign` may use
  the key. The setup script signs a test binary at the end specifically so that
  question gets asked there rather than mid-build.
- Keychain items the app created under its old ad-hoc identity prompt once more
  after the switch, for the same reason — "Always Allow" adds the certificate to
  the item's ACL, and from then on it holds.
- The identity is per-machine. To have a second machine build the *same*
  application rather than a different one, move the identity rather than
  generating another: `local_identity export ~/id.p12` on the first machine and
  `local_identity ensure --import ~/id.p12` on the second.
- `--config=local_signed` is not a distribution path. A self-signed certificate
  has no Apple-issued chain, so it cannot notarize and cannot carry hardened
  runtime (library validation rejects its Team ID) — `//bazel:codesign.bzl`
  strips `--options=runtime` for it exactly as it does for ad-hoc. Release
  builds still go through `--config=developer_id` / `--config=appstore_release`.

### App Store configuration

`--config=appstore` signs with **Apple Development** (`STORE_IDENTITY` in `bazel/signing.bzl`) and
embeds the development profile `macapp/GarageRAGDevelopmentApp.provisionprofile`, so the sandboxed
store build runs on the Macs that profile lists. An Apple Distribution–signed build with a store
profile cannot launch locally. Uploading re-signs the archive in Xcode (Organizer → Distribute App)
with Apple Distribution and the store profile, `macapp/GarageMacAppConnect.provisionprofile`; run
Validate App first so Xcode confirms it re-signs the nested code (Postgres in `Resources/`, the
site-packages extensions, `Python.framework`). To run a store build on another Mac, add that Mac to
the development profile in the developer portal and replace the file.

`--config=appstore` is a fastbuild, so it shares the `//ext` builds (Postgres, ICU, Python,
llama.cpp, …) with the ad-hoc and Developer ID configs; only the codesign steps differ. Build the
archive you upload with `--config=appstore_release`, which is the same config plus
`--compilation_mode=opt` and therefore rebuilds everything optimized.

The first launch of a store build on a Mac that already ran the Developer ID build asks for Keychain
access to the Postgres password item (`com.rickmark.garage.postgres`): the Developer ID build created
it, and its access list names only that signature. Answer **Always Allow** once.

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
`--with-icu --with-libedit-preferred --with-zlib --with-template=darwin --disable-rpath`
as an arm64 binary. ICU and zlib are built as dylibs under `//ext` and shipped
in `postgres/lib`, with `//ext/postgres:postgres_rpath` pointing the binaries at
them via `@executable_path/../lib`. Line editing for psql comes from the macOS
SDK's libedit (`/usr/lib/libedit.3.dylib`), not GPL-3.0 GNU Readline. The
standalone `libpq.dylib` in `Contents/Frameworks` gets its own install name
fixed up separately (`//ext/postgres:libpq_dylib`, signed by
`//macapp/externals:libpq`).

One more non-obvious thing found along the way: this build of `postgres`
fails to start with `FATAL: postmaster became multithreaded during startup`
unless `LC_ALL=C` is set in its environment (`PostgresService.swift` does
this). Locale initialization on this platform spins up threads before
postgres's fork-safety check runs.

## Building against Postgres 19 (beta)

The Bazel build carries two Postgres externals: `//ext/postgres` (18, the
default) and `//ext/postgres19` (19beta4, pinned by commit). Both share one
build definition (`ext/postgres/postgres.bzl`); each has its own copy of the
sandbox patch, since 19 replaced the semaphore/shmem sizing API the patch hooks
into. Select 19 for the whole tree (pgvector, the bundled server, libpq) with:

```bash
aspect build //:macapp --config=pg19   # same as --//ext:postgres_version=19
```

Data directories are not compatible across major versions. Switching an existing
install from 18 to 19 (or back) means dumping and restoring the data folder's
`pgdata`, or running `pg_upgrade`.

## Auto-update (Developer ID only)

Developer ID builds update themselves through [Sparkle](https://sparkle-project.org),
vendored as a prebuilt framework in `//ext/sparkle`. App Store builds embed no
Sparkle at all — Apple rejects apps that update themselves — so the whole thing
is behind `select()`s on `//bazel:is_store`:

- `//macapp/Sources/GarageUpdater` compiles `SparkleUpdaterBackend.swift` for
  Developer ID (and local ad-hoc) builds and the inert `AppStoreUpdaterBackend.swift`
  for the store, which is also what keeps `@sparkle` out of that dependency graph.
- `Sparkle.plist` (SUFeedURL, SUPublicEDKey, SUScheduledCheckInterval) is merged
  into the app's `Info.plist` for the same configurations.

The app never shows a disabled "Check for Updates…"; when the running build
can't update itself the item is simply absent. Whether to check automatically is
Sparkle's own question, asked on the second launch.

### The signing key

Sparkle verifies every downloaded update against an EdDSA public key baked into
the app. The pair already exists: the public half is `SUPublicEDKey` in
`macapp/Sources/GarageApp/Sparkle.plist`, and the private half is in the login
Keychain of the machine that ran

```bash
aspect run //ext/sparkle:generate_keys
```

Back that Keychain item up. It is the only thing that can sign an update the
shipped app will accept, and it is never committed — losing it means minting a
new pair and persuading users of the old one to install a new build by hand.

A fork or a fresh checkout that regenerates the pair has to paste the new public
key into `Sparkle.plist`. Left as `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`, the app
reports "This build was made without a Sparkle signing key" rather than fetching
a feed it could not verify.

### Cutting a release

1. `aspect build //macapp/package:GarageApp` stages and signs the app, producing
   `bazel-bin/macapp/package/GarageApp.zip` — a zip of `Garage.app`, which is
   exactly the shape Sparkle wants to download. This is also the step that
   re-signs Sparkle's nested code (see below).
2. `aspect run //macapp/package:notarize_all` submits that archive and the
   installer `.pkg` to the notary service.
3. Put the archive, named for its version, in an otherwise empty directory
   together with a copy of the current `docs/appcast.xml`, so the existing
   entries are carried over rather than dropped. Then:

   ```bash
   aspect run //ext/sparkle:generate_appcast -- \
       --download-url-prefix https://github.com/rickmark/garage-rag/releases/download/<tag>/ \
       "$PWD/release-dir"
   ```

   It reads the archive's `CFBundleShortVersionString`/`CFBundleVersion`, signs
   the entry with the private key from the Keychain, and rewrites `appcast.xml`.

   `--download-url-prefix` is not optional here. The feed is served from GitHub
   Pages but the archives live on GitHub Releases, so without it the enclosure
   URLs come out relative to the feed and every download 404s. The prefix
   applies to every archive in the directory, which is why each run publishes
   one release: archives from an older tag would be given this tag's URL.
4. Upload the archive to the GitHub release under `<tag>`, copy the generated
   `appcast.xml` over `docs/appcast.xml`, and commit. GitHub Pages serves it at
   `https://garagerag.app/appcast.xml`, which is the SUFeedURL.
5. Before announcing it, fetch the feed and check that each `<enclosure url=…>`
   is the GitHub Releases URL of an asset that actually exists.

`//ext/sparkle:sign_update` signs a single archive if you need to patch an entry
by hand. `//ext/sparkle:binary_delta` builds the delta patches `generate_appcast`
attaches when it finds `BinaryDelta` alongside itself — without them every user
downloads the whole app rather than a diff.

### Why the framework is re-signed

The hardened runtime turns on library validation, so a `Sparkle` dylib still
carrying the Sparkle Project's Team ID would refuse to load into Garage.
rules_apple's imported-framework processor re-signs `Sparkle.framework/Versions/B`
with the embedding app's identity when it bundles it, and `macos_lipo_app`
re-signs the nested `Updater.app` and `XPCServices/*.xpc` on the way to
notarization.

## First-run setup assistant

On a fresh install (no `garage.firstRun.completed` default) the main window opens straight into a
four-page assistant instead of the sidebar UI:

1. **Setting things up** — starts the bundled Postgres, applies pending migrations, and brings up the
   gRPC and MCP daemons, showing each as a checklist row. It advances by itself once the database,
   schema and gRPC bridge are ready (MCP is optional here so a port clash can't trap the user).
   An install that already has sources in `~/.garage.json` or models in the database skips the rest.
2. **Select your data** — template sources (Documents, Desktop, Downloads, iCloud Drive, Dropbox,
   `~/Developer`, Messages, Mail) with unavailable ones greyed out, plus a custom folder chooser.
   "Next" sends an `AddSource` RPC for each pick; "I'll decide later" moves on without adding any.
3. **Select your models** — an optional fact-distillation preset, then text embedding presets (featured
   first; the first pick becomes the default) from `models.json`; distillation comes first so the
   second section is not missed below a long embedding list. "Next" sends `RegisterModel` for each
   embedding model, sets `facts.model`/`facts.provider` for the distillation pick, and, if enabled,
   queues GGUF downloads through the model download XPC service.
4. **Set up your agent** — MCP server status/port and the detected client configs (Claude Desktop,
   Claude Code, Cursor, …); "Connect selected agents" registers Garage in each selected config.

The flow lives in `Services/FirstRunCoordinator.swift` (state + the commands each page runs) and
`Views/FirstRunView.swift` (the pages). It can be re-run any time from **Garage ▸ Setup Assistant…**
or the menu bar item, and skipped from any page.

**Reset Database…** relaunches into the assistant too, whether or not it was completed before. There
page 1 also creates the new, empty database and registers the sources in `~/.garage.json` again
(`AppState.finishDatabaseReset`) before offering the rest. Skipping before page 1 gets that far
finishes the reset in the background, so the main window comes up on the new database, unconfigured,
with the Status page's quick-add cards.

## App architecture

- `PostgresService` — owns a private cluster in `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/pgdata`, port 14824, database `garage-rag`. On first initialization it generates a random Postgres superuser password, stores it in the macOS Keychain, and creates the cluster with SCRAM authentication.
- `OperationRunner` — runs the app's operations (scan, add-source, register-model, sync, …) as calls on the Python `GarageService` over gRPC, logging what each reports. Dedicated runners and log streams exist for the long-running `backfill` and `enrich-facts` streams so they never block ordinary operations; cancelling one stops the work server-side.
- `IngestService` — runs ingestion through `GarageIngestXPCService` (an XPC helper that embeds Python and calls `garage_rag.ingest` directly), receiving live progress and log callbacks over the connection. Ingest does not go through the CLI.
- `GarageMCPService` — owns the loopback HTTP `garage-mcp` server at `http://127.0.0.1:8787/mcp`, hosted inside the `GarageMCPServerService` XPC helper; started after Postgres and stopped before it.
- `GarageGRPCService` — owns the `GarageService` gRPC backend (port 50051) hosted inside the `GarageXPCService` helper; the Search and Documents views talk to it over gRPC-Swift.
- `LlamaService` / `ModelDownloadService` — drive the `LlamaXPCService` and `ModelDownloadXPCService` helpers through the `LlamaClient` / `ModelDownloadClient` modules.
- `LlamaXPCService` runs llama.cpp in-process (`Sources/LlamaEngine`, linked from `//ext/llama_cpp` with Metal and Accelerate). Besides its XPC interface it listens on `http://127.0.0.1:8790` with the llama-server routes (`/health`, `/props`, `/v1/models`, `/v1/embeddings`, `/v1/chat/completions`, `/completion`, `/tokenize`, `/detokenize`, `/v1/rerank`); that port is how the Python `llama_xpc` provider embeds and distills facts. `GARAGE_LLAMA_HTTP_PORT` in the helper's environment overrides the port; the Python side reads `embedding.llama_host` from `garage.json`.
- `XPCServiceManager` — pings all six helpers, streams their logs into the app, runs their in-service self tests and can restart or terminate them.
- `AppDelegate` — keeps the app running in the menu bar after the window closes, and signals Postgres and every helper to stop on every quit path (Cmd+Q, Dock quit, menu item).
- Views: Status, Sources & Ingest, Models, Search, Documents, Logs, MCP Server. Sources
  provides manual ingestion and an optional persisted schedule that ingests all
  sources and then backfills every registered model. The Models view
  provides controls for Llama models and embedding models: it includes
  the model catalog (`data/models/models.json`) and fills each selection's slug, dimensions,
  provider-side reference, and default provider. The provider can then be
  changed between Ollama and LM Studio; start the selected provider locally
  before backfilling embeddings. An LM Studio API token can be saved in the
  macOS Keychain from this view and is passed as `GARAGE_LMSTUDIO_API_TOKEN`
  to the gRPC server.

The app-managed HTTP MCP server has its own lifecycle and logs. Claude
Desktop/Code can instead spawn the bundled `garage-mcp` over stdio when
registered with `garage mcp-install --stdio`; this allows both connection modes.
The app hands the authenticated database URL to its XPC helpers as
`GARAGE_DATABASE_URL`. A stdio registration names the bundled `garage-mcp`,
which starts the app if needed and reads the password from the Keychain, so the
client's config carries no database URL or password. The first connection from
a launcher may show a Keychain prompt; choose Always Allow.

The Status view also provides database reset, backup, and restore controls.
Backups are PostgreSQL custom-format dumps; restore replaces the private Garage
database, while reset recreates it empty.
