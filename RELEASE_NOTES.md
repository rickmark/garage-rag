# Release Notes

## v0.10.0 — Final Beta (unreleased)

_Changes since [v0.9](https://github.com/rickmark/garage-rag/releases/tag/v0.9) — 50 commits, 215 files touched._

This is the final planned beta before 1.0. It closes out the native macOS app's process
architecture (every pipeline stage now runs as an isolated, statically-linked XPC service),
finishes the embedded Python runtime used to run the ingest/embed backends without a system
Python, and adds the public documentation site. CI is green again after this release (see
below) — it had been broken since the workflow was introduced.

### Highlights

- **Embedded Python runtime for `GarageApp`.** The macOS app now embeds CPython directly
  (`GaragePythonEmbed`, `GaragePythonRuntime`) instead of shelling out to a system interpreter,
  eliminating an entire class of `dyld`/`libpython`/`site-packages` path resolution failures
  that had been plaguing local runs and packaging.
- **XPC service architecture finished.** `GarageXPCService`, `GarageIngestXPCService`,
  `GarageEmbedXPCService`, `GarageMCPServerService`, `LlamaXPCService`, and
  `ModelDownloadXPCService` are now all statically linked, independently sandboxed helper
  processes that talk to `GarageApp` over gRPC (`proto/garage.proto`) rather than in-process
  calls or dynamic linking — a crash or hang in one pipeline stage (e.g. a bad PDF during
  ingest) no longer takes down the app or other in-flight work.
- **Bundled, relocatable PostgreSQL.** The app now ships and initializes its own PostgreSQL +
  pgvector instance (`macapp/externals/{Postgres,Initdb}Info.plist`, bundled
  `postgresql.conf`) rather than depending on a system install.
- **MCP server hardening.** `garage_rag/mcp_server/server.py` and the app's gRPC/XPC bridge
  were substantially reworked for correctness and stability of the MCP 2.0 integration used by
  Claude Desktop, Claude Code, and other MCP clients.
- **Public documentation site.** The full support/troubleshooting/FAQ/privacy documentation set
  now also publishes to **https://rickmark.github.io/garage-rag/** via GitHub Pages, in addition
  to the in-repo `docs/*.md` files linked from the README.
- **App size and startup work.** Several passes ("Size reduce") trimmed the bundled Python
  site-packages and codesigning/packaging pipeline, and ingest was reworked multiple times for
  correctness and throughput ("Improve ingest", "Working ingest", "ingest xpc").
- **App Store packaging explored and reverted.** App Store distribution changes were attempted
  and then intentionally backed out in this cycle; direct/developer-ID distribution remains the
  supported path for this beta.
- **Expanded test coverage.** New unit and UI test suites were added for the XPC protocol layer,
  ingest client, process runner, app state, splash/status/log views, and the Llama client
  (`macapp/Tests/**`), plus additional `garage_python` tests.

### Fixed

- **GitHub Actions CI was failing on every run since it was introduced.** All five `ci.yaml`
  jobs (`test`, `gazelle`, `buildifier`, `format`, `lint`) installed the Aspect CLI with
  `brew install aspect bazelisk`, but `aspect` is not a Homebrew core formula — every run
  failed in ~20 seconds at the "Install dependencies via Brew" step before ever invoking Bazel.
  CI now installs from Aspect's own tap: `brew install aspect-build/aspect/aspect bazelisk`.
  (The GitHub Pages docs-deploy workflow was unaffected and has been green throughout.)

### Known limitations

- App Store distribution is not currently supported (see above); use direct/developer-ID
  builds.
- Windows and Linux are not supported for `GarageApp`; the Python CLI/MCP server run on any
  platform with PostgreSQL + pgvector available.

### Upgrading

No database migrations are required beyond the existing `garage init-db` schema application.
If you're running an app built before this release, reinstall `GarageApp` to pick up the new
bundled Python runtime and XPC services — mixed old/new binaries are not supported.

---

## Previous releases

- [v0.9 — Beta Release](https://github.com/rickmark/garage-rag/releases/tag/v0.9)
- [v0.8.10 — Beta](https://github.com/rickmark/garage-rag/releases/tag/v0.8.10)
- [v0.7 — Alpha v0.7.2](https://github.com/rickmark/garage-rag/releases/tag/v0.7)
- [v0.6 — Alpha Release](https://github.com/rickmark/garage-rag/releases/tag/v0.6)

See the [GitHub Releases page](https://github.com/rickmark/garage-rag/releases) for the full
history and diff links between tags.
