# M4 validation report — PR #15 / `claude/adoring-ritchie-c084cj`

Machine: macOS 27.0 (build 26A428), Xcode 27.0 (27A266a), aspect launcher 2026.35.26.
Validation worktree: `../garage-validate`, detached. Nothing was fixed; nothing was pushed to
`claude/adoring-ritchie-c084cj`. No notarize / installer / install / `xcarchive_open` target ran.

**CLI note:** this aspect launcher rejects a bare `--config` — `error: unexpected argument
'--config' found`. Use `--bazel-flag=--config=adhoc`.

Commit history of this validation effort: round 1 `56b9a16`, round 2 `20407f3`, re-confirmed on
`2522845`, round 5 `b289b70`, round 6 `7677dac`, **this round `4139dbb`** ("Drop the second OSLog
poller and the Logs page's dead predicates (#27)"), which is a descendant of the requested
`7828704`.

---

## 1. Build — PASS

```
aspect build --bazel-flag=--config=adhoc //:macapp
```
Passed in 6m57s. **Zero compile errors.** `7828704`'s fix for the previous
`SourcePresets.swift:72` error is confirmed present — `registerModel(preset:)` now reads
`return await runOperation(...)`.

Four first-party warnings (zero from `external/` — vendored deps were action-cache hits this run,
so their diagnostics were not re-emitted):

```
macapp/Sources/GarageIngestXPCService/main.swift:345:36: warning: capture of 'requester' with non-Sendable type 'NSXPCConnection?' in an isolated local function; this is an error in the Swift 6 language mode
macapp/Sources/GarageApp/Services/IngestService.swift:333:13: warning: initialization of immutable value 'runStartDate' was never used; consider replacing with assignment to '_' or removing it
macapp/Sources/GarageApp/Services/XPCServiceManager.swift:242:25: warning: reference to captured var 'manager' in concurrently-executing code; this is an error in the Swift 6 language mode
macapp/Sources/GarageApp/Services/XPCServiceManager.swift:245:25: warning: reference to captured var 'osLogStreamService' in concurrently-executing code; this is an error in the Swift 6 language mode
```

`IngestService.swift:333` (`runStartDate` never used) is the only new one — likely a leftover from
the gRPC migration.

## 2. Tests — 8 pass, 17 fail (24 of 25 executed; `test_config` cached)

```
aspect test --bazel-flag=--config=adhoc --bazel-flag=--keep_going --bazel-flag=--test_output=errors //garage_python/... //macapp/Tests/GarageAppUnitTests:GarageAppUnitTests
```

Passing: `test_config`, `test_attribution`, `test_chunking`, `test_facts`, `test_generation`,
`test_llama_embedder`, `test_llama_xpc`, `test_lmstudio`.

Failing target → first failing test → cause:

| target | first failing test | cause |
|---|---|---|
| `test_cli_serve` | collection error | libpq |
| `test_dedicated_rpcs` | `test_dedicated_rpc_version` | `garage_rag.__version__` |
| `test_egress_block` | `TestCommunicationSourcesStayLocal::test_add_source_refuses_before_touching_the_database` | libpq |
| `test_embed_egress` | `TestEmbedWorkerBatches::test_off_box_provider_gets_no_communications` | `garage_rag.db.engine` |
| `test_embed_xpc` | `test_servicer_get_embedding_batches_and_update` | `garage_rag.db.engine` |
| `test_grpc_documents` | `test_grpc_list_documents_empty_filters` | `garage_rag.db.engine` |
| `test_grpc_operations` | collection error | libpq |
| `test_grpc_serialization` | `test_client_in_process_version` | `garage_rag.__version__` |
| `test_grpc_server` | `test_grpc_get_status` | `garage_rag.db.engine` |
| `test_ingest_gateway` | `test_grpc_database_facade_servicer_methods` | `garage_rag.db.engine` + counters |
| `test_ingest_xpc` | `test_ingest_xpc_with_grpc_options` | `garage_rag.service` |
| `test_mcp_install` | collection error | libpq |
| `test_mcp_server` | collection error | libpq |
| `test_migrate` | collection error | libpq |
| `test_registry_dims` | `TestSearchBindType::test_halfvec_model_binds_a_halfvec_parameter` | libpq |
| `test_scanner` | collection error | libpq |
| `GarageAppUnitTests` | `AppStateTests.testCombinedIngestProgressUsesPriorScanTotalsAcrossSources` | assertion |

`test_embed_egress` is new in this commit and fails on the runfiles gap.

### Swift unit tests

218 tests, 2 failures — both the same test:

```
/private/tmp/macapp/Tests/GarageAppUnitTests/AppStateTests.swift:410: error: -[GarageAppUnitTests.AppStateTests testCombinedIngestProgressUsesPriorScanTotalsAcrossSources] : XCTAssertEqual failed: ("600") is not equal to ("1000")
/private/tmp/macapp/Tests/GarageAppUnitTests/AppStateTests.swift:411: error: -[GarageAppUnitTests.AppStateTests testCombinedIngestProgressUsesPriorScanTotalsAcrossSources] : XCTAssertEqual failed: ("600") is not equal to ("1000")
```

### `test_egress_block` — the privacy invariants still hold

Worth stating plainly: the failure is **not** a privacy regression. 13 of 16 subtests pass,
including every load-bearing one — `test_communication_cannot_be_constructed`,
`test_communication_blocked_even_when_source_allows`,
`test_only_egress_module_imports_anthropic`, `test_no_module_constructs_a_client_outside_egress`.
The 3 failures are the libpq chain newly reaching this file via
`from garage_rag.ops.sources import SourceArgumentError, add_source`. The guarantee is intact, but
the guard is now environment-dependent where it previously was not.

---

## 3. The six blockers

### (a) xcarchive ships an unsigned `Python.framework`

```
aspect build //macapp:GarageStore.xcarchive        # PASSES
codesign --verify --deep --strict --verbose=2 \
  bazel-out/darwin_arm64-fastbuild-ST-37fe811ccc69/bin/macapp/Garage.xcarchive/Products/Applications/Garage.app
```
```
Garage.app: code object is not signed at all
In subcomponent: .../Garage.xcarchive/Products/Applications/Garage.app/Contents/Frameworks/Python.framework
```
Direct check of the framework:
```
.../Garage.xcarchive/.../Contents/Frameworks/Python.framework: code object is not signed at all
```
The **same** framework inside `GarageStore.app` is correctly signed:
```
Authority=Apple Distribution: Richard Penwell (DWVXMLB45Y)
Signature size=4788
```
So the archive staging drops the signature. Likely App Store submission blocker.

File: `bazel/xcarchive.bzl` — `_raw_xcarchive` forwards rules_apple's xcarchive
`OutputGroupInfo` at **`bazel/xcarchive.bzl:24`** under the `universal_store` transition
(**`bazel/xcarchive.bzl:7-16`**). Stated as observation: a single guilty line was not isolated.

### (b) `//macapp/package:GarageApp` does not transition to the Developer ID platform

```
aspect build //macapp/package:GarageApp
```
```
ERROR: /Users/rickmark/Developer/garage-validate/garage_python/BUILD.bazel:37:9: Codesigning @@//garage_python:site-packages failed: (Exit 1): bash failed: error executing Codesign command (from codesign rule target //garage_python:site-packages)
Garage Local Signing: no identity found
Target //macapp/package:GarageApp failed to build
```

Root cause, confirmed in source: **`bazel/lipo.bzl:238-241`** declares `macos_lipo_app`'s `app`
attribute as a plain `attr.label(mandatory = True)` with **no `cfg`**, whereas
**`bazel/macos_application.bzl:123-125`** uses `cfg = _developer_id_transition`. So
`//macapp/package:GarageApp` (**`macapp/package/BUILD.bazel:10-17`**) pulls
`//macapp/Sources/GarageApp:GarageApp` under the **default local_signed** platform instead of
`//bazel:universal_developer_id`.

Caveat: the verbatim error above was captured at `2522845`. At `7677dac` and later the target
fails earlier, so it was not re-confirmed at this commit. The transition gap is present in source
regardless, and means the packaged app is signed under the wrong platform.

### (c) Ingest counter regression

```
aspect test --bazel-flag=--config=adhoc //garage_python/tests:test_ingest_gateway
```
```
E           AssertionError: assert 0 == 1
E            +  where 0 = IngestCounters(seen=0, indexed=0, skipped=0, failed=0, placeholders=0, rejected=0, chunks_written=0, total_items=1, item_type='files', errors=[]).seen
```
At **`garage_python/tests/test_ingest_gateway.py:296`, `:564`, `:613`, `:642`** — still all four at
this commit. 6 of 10 tests in the file fail.

`counters.seen` stays 0 where 1 is expected: the gateway-routed ingest facade introduced in
`56b9a16` no longer counts seen items. Look at `garage_python/src/garage_rag/ingest/pipeline.py`
and `garage_python/src/garage_rag/ingest/gateway.py`.

### (d) Runfiles / dep-graph gap

```
aspect test --bazel-flag=--config=adhoc //garage_python/tests:test_dedicated_rpcs
```
```
E       AttributeError: module 'garage_rag' has no attribute '__version__'
garage_python/src/garage_rag/service/server.py:87: AttributeError
```
Raised inside `_version()` even though **`garage_python/src/garage_rag/__init__.py:8`** defines
`__version__ = "0.1.0"`. Sibling forms:

- `AttributeError: module 'garage_rag.db' has no attribute 'engine'` — via `unittest.mock.patch`
  `resolve_name` on `patch("garage_rag.db.engine.session_scope")`,
  **`garage_python/tests/test_ingest_gateway.py:66`**
- `AttributeError: module 'garage_rag' has no attribute 'service'` — `patch("garage_rag.service.client.GarageClient")`,
  **`garage_python/tests/test_ingest_xpc.py:230`**
- over the wire: `grpc._channel._InactiveRpcError ... status = StatusCode.UNKNOWN`,
  `details = "Exception calling application: module 'garage_rag' has no attribute '__version__'"`

The `py_library` deps for the `service/` and `db/` subpackages omit the top-level `garage_rag`
`__init__`, so the sandboxed runfiles tree exposes `garage_rag` as a namespace package without its
`__init__` attributes.

### (e) New code pulls psycopg into previously DB-free tests

```
aspect test --bazel-flag=--config=adhoc //garage_python/tests:test_registry_dims
```
Passes on `origin/main` (`2f279de`); here 40 of 44 pass, 4 fail.
```
E           ImportError: no pq wrapper available.
E           Attempts made:
E           - couldn't import psycopg 'c' implementation: No module named 'psycopg_c'
E           - couldn't import psycopg 'binary' implementation: No module named 'psycopg_binary'
E           - couldn't import psycopg 'python' implementation: libpq library not found
```
Chain: **`garage_python/tests/test_registry_dims.py:205`** (helper `_run`)
`from garage_rag.search import hybrid` → **`garage_python/src/garage_rag/search/hybrid.py:30`**
`from garage_rag.db.engine import apply_search_tuning` →
**`garage_python/src/garage_rag/db/engine.py:15`** `import psycopg`.

Failing: `TestSearchBindType::test_halfvec_model_binds_a_halfvec_parameter`,
`::test_truncated_mrl_model_binds_a_halfvec_of_the_stored_width`,
`::test_vector_model_binds_a_vector_parameter`, `::test_fts_mode_needs_no_model`.

Same pattern now also reaches `test_egress_block` (via `garage_rag.ops.sources`) and
`test_grpc_operations` (**`garage_python/src/garage_rag/ops/backfill.py:10`** →
`db/engine.py:15`).

Note: the other libpq failures (`test_cli_serve`, `test_mcp_install`, `test_mcp_server`,
`test_migrate`) reproduce identically on `origin/main` — those are this machine lacking libpq, not
the PR.

### (f) New codesign tests check the wrong paths

Both targets are new in this PR (absent on `origin/main`) and both fail.

```
aspect test --bazel-flag=--config=adhoc //ext/pythonkit:pythonkit_codesign_test
```
```
Checked 0 Mach-O binaries: 0 passed, 0 failed
Error: No Mach-O binaries were found in target inputs
```
Emitted at **`bazel/codesign_test.bzl:240`**, because the `find "$STAGE_DIR" -type f` sweep at
**`bazel/codesign_test.bzl:233`** yields nothing for that target — it supplies no Mach-O inputs.

```
aspect test --bazel-flag=--config=adhoc //ext/python:python_framework_codesign_test
```
```
/var/folders/.../stage/Python.framework: bundle format is ambiguous (could be app or framework)
[FAIL] Bundle verification failed: Python.framework
/var/folders/.../stage/Python.framework/Python: bundle format is ambiguous (could be app or framework)
[FAIL] Python.framework/Python: codesign verification failed
[PASS] Python.framework/Versions/3.13/Python
[PASS] Python.framework/Versions/Current/Python
Checked 3 Mach-O binaries: 1 passed, 2 failed
```
The bundle sweep at **`bazel/codesign_test.bzl:154`**
(`find "$STAGE_DIR" -maxdepth 3 -type d \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" \)`)
hands the framework wrapper and the top-level `Python` symlink to `codesign --verify`, instead of
restricting to the versioned binary — which passes.

---

## 4. Runtime checks (step 5)

The built app is ad-hoc signed and was run from a scratch directory.

### Root cause for 5a / 5c / 5f / 5g: an unanswered Keychain prompt

The app **launches** (its process and its `GarageIngestXPCService` / `GarageEmbedXPCService`
children are all alive) but **Postgres never starts** — no `postmaster.pid` is ever created in
`~/Library/Application Support/GarageApp/pgdata`, and `pg_ctl status` reports `no server running`.
The app emits no log output at all while this happens.

Evidence this is a Keychain gate, not a Postgres fault:

- The cluster is healthy and version-matched: `PG_VERSION` is `18`, the bundled `pg_ctl` is
  `pg_ctl (PostgreSQL) 18.6`.
- The DB superuser password lives in the Keychain — `security find-generic-password -s
  "com.rickmark.garage.postgres"` returns `"acct"<blob>="postgres-superuser"`. The item exists.
- The freshly built app is `Signature=adhoc`, `TeamIdentifier=not set`, so its cdhash does not
  match the ACL on that Keychain item.
- `SecurityAgent` (`/System/Library/Frameworks/Security.framework/.../SecurityAgent`) was running
  immediately after the app launch — i.e. the prompt was on screen, with nobody to answer it.

This is precisely the situation `macapp/README.md` documents: *"Keychain items the app created
under its old ad-hoc identity prompt once more: the item's ACL still names the old cdhash, and
'Always Allow' is what adds this certificate to it."*

**The exact wording of the prompt could not be captured** — it is rendered by `SecurityAgent` in
its own process and is not readable from the shell. A human at the Mac would need to report it.

Consequently 5a, 5c, 5f and 5g could not be completed. They are **not** reported as product
failures; they are blocked on an interactive approval.

### 5a — `garage stats` — FAIL (blocked)

```
.../Garage.app/Contents/MacOS/garage stats
```
```
Starting Garage…
Garage started, but its database did not accept connections within 60s. Open Garage and check the Database page.
```
Exit 1. `Starting Garage…` on stderr is as expected, and the app did launch hidden. The 60s
timeout is the Keychain block above.

### 5b — CLI must not launch the app — **PASS**

```
.../Garage.app/Contents/MacOS/garage --help          # exit 0, usage printed
.../Garage.app/Contents/MacOS/garage config get facts.model   # exit 0
gemma2-2b
```
App process count was 0 before and 0 after both commands. Neither launches the app.

### 5c — `garage-mcp` JSON-RPC — FAIL (blocked), but log hygiene **PASS**

```
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize",...}' | .../Contents/MacOS/garage-mcp
```
stdout was **empty**; stderr:
```
Starting Garage…
Garage started, but its database did not accept connections within 60s. Open Garage and check the Database page.
```
Exit 1. So `initialize` is not answered — worth asking whether an MCP `initialize` handshake
*should* require the database at all, since it carries no corpus data.

Log hygiene passes: `log show --last 5m --predicate 'category == "GarageCLI"'` contains exactly one
line, and it is not JSON-RPC:
```
2026-09-22 15:31:27.471 E  garage[52465:f55673] [me.rickmark.garage-rag:GarageCLI] INFO garage_rag.mcp_server.install: registered garage-rag in /private/tmp/mcp-test.json
```
A broader sweep for `jsonrpc|clientInfo|protocolVersion` across the whole unified log matched 15
lines, **none** of them from a Garage process. No JSON-RPC leaked into the log.

### 5d — `mcp-install` — **PASS**

```
.../Garage.app/Contents/MacOS/garage mcp-install --stdio --path /tmp/mcp-test.json --yes
```
`/tmp/mcp-test.json`:
```json
{
  "mcpServers": {
    "garage-rag": {
      "command": "/tmp/claude-501/-Users-rickmark-Developer-garage/c42be0c3-b89e-4f41-b04d-db7db938babe/scratchpad/r7/Garage.app/Contents/MacOS/garage-mcp",
      "args": []
    }
  }
}
```
Absolute path to the bundled `Contents/MacOS/garage-mcp`, **no `env`, no password**. (The path is
under the scratch directory only because that is where this build's bundle was unpacked.)

### 5e — `GARAGE_NO_APP_LAUNCH=1` — **PASS**

```
GARAGE_NO_APP_LAUNCH=1 .../Garage.app/Contents/MacOS/garage stats
```
```
Garage's database is not running, and GARAGE_NO_APP_LAUNCH is set. Open Garage, or unset it.
```
Exit 1, clear message, app not launched.

### 5f — GUI exercise — NOT PERFORMED

There is no macOS GUI automation tool available in this session, so the SwiftUI controls (add
source, Sync, Reconcile dry run, Scan, register preset, Backfill + Cancel, Show stats, Check MCP
Status) cannot be driven. No results are invented. It is blocked on the Keychain prompt regardless.

### 5g — migration 008 + 4096-dim model — NOT PERFORMED

Running this was authorised, but it requires a live database, and the database cannot be brought up
without a human answering the Keychain prompt. `garage register-model bq-test --dims 4096 ...`,
`garage search "test" --model bq-test --mode vector` and `garage drop-model bq-test --yes` were
**not** run, and **migration 008 was not applied**. The existing `pgdata` (299 MB) is untouched.

---

## What to fix, in rough priority order

1. **xcarchive unsigned `Python.framework`** — blocks App Store submission.
2. **Ingest counter regression** (`counters.seen` stays 0) — real behavioural bug.
3. **Runfiles/dep-graph gap** — masks 6 test targets, and would break `garage version` and any
   `db.engine` access in a packaged context.
4. **`macos_lipo_app` missing the Developer ID transition** — packaged app signed under the wrong
   platform.
5. **New psycopg imports** dragging DB dependencies into previously DB-free tests, including the
   egress guard.
6. **Codesign test paths** — two new tests that cannot pass as written.
