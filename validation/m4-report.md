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

---

# Round 2 — re-validation at `ef303db`

Re-run against `claude/adoring-ritchie-c084cj` at **`ef303db`** ("Fix combined batch progress; let
garage-mcp answer before Postgres is up"), on top of `2cf8433` ("Sign what the xcarchive and lipo
app actually ship") and `39f9561` ("Let the Bazel tests import garage_rag and reach libpq; stop
importing psycopg eagerly").

Same machine and toolchain as round 1: macOS 27.0 (26A428), Xcode 27.0 (27A266a), aspect launcher
2026.35.26. Nothing was changed on `claude/adoring-ritchie-c084cj`. No notarize / installer /
install / `xcarchive_open` target ran.

Scope note: steps 6 (migrations 008/009, binary-quantized search) and 7 (`garage-mcp` initialize
timing) were reassigned to the M3 mid-round and are **not** covered here. Step 4 was **skipped at
the user's request**.

| Step | Result |
|---|---|
| 1. `aspect build //...` | **FAIL** — Bazel load error, nothing builds |
| 2. `aspect test //...` | **FAIL** — same load error, no tests run |
| 3. xcarchive + codesign | **PASS** — blocker (a) fixed |
| 4. `//macapp/package:GarageApp` | skipped at user's request |
| 5. `//ext/python:python_framework_codesign_test` | **FAIL** — new error |

## Step 1 — `aspect build //...`: FAIL (exit 1, 0.6s)

This is a **load-phase failure**: the target pattern `//...` cannot be evaluated, so no target in
the repository builds, and nothing downstream of it can be assessed.

```
ERROR: Traceback (most recent call last):
	File "/Users/rickmark/Developer/garage-validate/garage_python/tests/BUILD.bazel", line 3, column 8, in <toplevel>
		py_test(
	File "/Users/rickmark/Developer/garage-validate/tools/pytest/defs.bzl", line 46, column 20, in py_test
		_py_pytest_test(
	File ".../external/aspect_rules_py+/py/private/py_pytest_test.bzl", line 121, column 32, in py_pytest_test
		main = pytest_driver_wiring(
	File ".../external/aspect_rules_py+/py/private/py_pytest_test.bzl", line 73, column 16, in pytest_driver_wiring
		data = list(kwargs.pop("data", []))
Error in list: in call to list(), parameter 'x' got value of type 'select', want 'iterable'
ERROR: package contains errors: garage_python/tests
WARNING: Target pattern parsing failed.
```

**Cause.** `39f9561` added the macOS libpq wiring at **`tools/pytest/defs.bzl:49-52`**:

```starlark
data = data + select({
    "@platforms//os:macos": [_LIBPQ],
    "//conditions:default": [],
}),
```

`aspect_rules_py` 2.0.0-alpha.6 (**`MODULE.bazel:29`**) cannot accept a `select` there:
`pytest_driver_wiring` does `data = list(kwargs.pop("data", []))` at
**`py_pytest_test.bzl:73`**, and `list()` rejects a `select`. Because the macro is used by every
`py_test` in `garage_python/tests/BUILD.bazel`, the whole package fails to load, which fails
`//...`.

The sibling `env = select({...})` at **`tools/pytest/defs.bzl:53`** is fine — `env` is not passed
through `list()`.

## Step 2 — `aspect test //...`: FAIL (exit 1, 0.6s)

Identical load error; **zero tests executed**, so there is no per-target failure list to give.

```
ERROR: Error evaluating '//...': error loading package 'garage_python/tests': Package 'garage_python/tests' contains errors
```

Consequently the previously reported Python findings could **not** be re-checked at this commit:
the ingest-counter regression (`counters.seen`), the `garage_rag` runfiles gap, and the psycopg
import creep are all **unverified here** — neither confirmed fixed nor confirmed still broken.
`39f9561` is intended to address the latter two, but that cannot be observed until the load error
is resolved.

## Step 3 — xcarchive: PASS — blocker (a) is fixed

```
aspect build //macapp:GarageStore.xcarchive
```
Exit 0, 5m43s. Output:
`bazel-out/darwin_arm64-fastbuild-ST-37fe811ccc69/bin/macapp/_GarageStore_xcarchive_raw/Garage.xcarchive`

The app inside the archive:
```
.../Garage.xcarchive/Products/Applications/Garage.app: valid on disk
.../Garage.xcarchive/Products/Applications/Garage.app: satisfies its Designated Requirement
```
```
Identifier=me.rickmark.garage-rag
Authority=Apple Distribution: Richard Penwell (DWVXMLB45Y)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=DWVXMLB45Y
```

And the framework that previously failed:
```
.../Garage.app/Contents/Frameworks/Python.framework: valid on disk
.../Garage.app/Contents/Frameworks/Python.framework: satisfies its Designated Requirement
```

Round 1 reported `code object is not signed at all / In subcomponent: ... Python.framework`.
That is resolved — `2cf8433`'s ditto-based assembly works.

## Step 4 — `//macapp/package:GarageApp`: SKIPPED

Not run, at the user's explicit request. The Developer ID authority chain on the lipo'd universal
app is therefore **unverified**. Note the round-1 root cause (`macos_lipo_app`'s `app` attribute
lacking `cfg = _developer_id_transition`, `bazel/lipo.bzl:238-241`) is reported fixed by
`2cf8433`, but that claim is not checked here.

## Step 5 — `//ext/python:python_framework_codesign_test`: FAIL (exit 3)

Still failing, but with a **different** error than round 1 — the symlink fix changed the failure
mode rather than removing it.

```
Verifying bundle: Python.framework
/var/folders/.../codesign_test.EteXJy/stage/Python.framework: Too many levels of symbolic links
[FAIL] Bundle verification failed: Python.framework
============================================================
Checked 0 Mach-O binaries: -1 passed, 1 failed
============================================================
Error: No Mach-O binaries were found in target inputs
```

Round 1 was `bundle format is ambiguous (could be app or framework)` with `1 passed, 2 failed`.
Now the staged copy has a symlink cycle, `codesign` refuses it, and **no** binaries get checked at
all.

Two distinct problems:

1. **Symlink cycle in the staged tree.** `2cf8433` replaced the copy with
   **`bazel/codesign_test.bzl:114`**:
   `tar -cf - -C "$item" . | (cd "$STAGE_DIR/$(basename "$item")" && tar -xf -)`.
   This preserves symlinks, which was the intent, but the resulting
   `Python.framework` staged this way resolves into a loop —
   `Versions/Current` → `Versions/3.13` and the top-level `Python`/`Resources`
   entries pointing back through `Current` — so `codesign` reports
   `Too many levels of symbolic links`.
2. **Counter arithmetic bug, independent of the above.** The summary prints `-1 passed` because
   **`bazel/codesign_test.bzl:239`** computes
   `$((total_checked - failed_count))` where `total_checked` is 0 (incremented only at
   **`:179`**, per Mach-O binary) while `failed_count` was incremented by the *bundle* failure.
   Bundle failures and binary failures are counted against different denominators. Even once the
   symlink issue is fixed, this line can report a negative pass count.

`//ext/pythonkit:pythonkit_codesign_test` is confirmed **removed**:
`ERROR: no such target '//ext/pythonkit:pythonkit_codesign_test': target 'pythonkit_codesign_test'
not declared in package 'ext/pythonkit'`.

## Round 2 summary

Fixed and verified: the xcarchive's unsigned `Python.framework`, and the removal of
`pythonkit_codesign_test`.

Still open:
1. **`tools/pytest/defs.bzl:49` breaks the whole build graph** — the `select` in `data` is
   incompatible with aspect_rules_py 2.0.0-alpha.6. This is the highest priority item: it blocks
   `//...` entirely, so it also hides whatever state the Python fixes in `39f9561` are actually in.
   Worth noting this is the second time a Bazel load error has masked the tree.
2. **`python_framework_codesign_test`** — symlink cycle in the tar-staged framework
   (`codesign_test.bzl:114`) plus a negative-count bug at `codesign_test.bzl:239`.

Unverified this round: the ingest-counter regression, the `garage_rag` runfiles gap, the psycopg
import creep (all blocked by step 1/2), and the Developer ID transition on
`//macapp/package:GarageApp` (step 4 skipped).

---

# Round 2b — `80c11fc`

Re-run after `096630a` ("Keep the pytest macro's data a plain list; sync BUILD deps with gazelle")
fixed the round-2 load error. Branch head **`80c11fc`**. Same machine and toolchain.
Nothing changed on `claude/adoring-ritchie-c084cj`; no notarize / installer / install /
`xcarchive_open` target ran. Step 4 (`//macapp/package:GarageApp`) remains **skipped at the user's
request** — that overrides the follow-up request's assumption that it had run.

The fix: `data` is a plain list again, with `select` kept only on `env`
(**`tools/pytest/defs.bzl:47-57`**), which is what aspect_rules_py 2.0.0-alpha.6 can accept.

## Step 1 — `aspect build //...`: **PASS**

Exit 0, 6m13s, **zero compile errors**. This is the first time the whole target pattern has built
in this validation effort.

Three first-party warnings, all pre-existing. The `runStartDate` warning reported at `4139dbb` is
**gone**:
```
macapp/Sources/GarageIngestXPCService/main.swift:345:36: warning: capture of 'requester' with non-Sendable type 'NSXPCConnection?' in an isolated local function; this is an error in the Swift 6 language mode
macapp/Sources/GarageApp/Services/XPCServiceManager.swift:242:25: warning: reference to captured var 'manager' in concurrently-executing code; this is an error in the Swift 6 language mode
macapp/Sources/GarageApp/Services/XPCServiceManager.swift:245:25: warning: reference to captured var 'osLogStreamService' in concurrently-executing code; this is an error in the Swift 6 language mode
```
Zero `external/` warnings (vendored deps were cache hits).

## Step 2 — `aspect test //...`: 26 pass, 4 fail

`Executed 29 out of 30 tests: 26 tests pass and 4 fail locally.`
(Round 1 at `4139dbb` was 8 pass / 17 fail.)

Failing targets and the first real error from each:

| target | first failing test | error |
|---|---|---|
| `test_ingest_gateway` | `test_ingest_source_with_grpc_gateway` | `AssertionError: assert 0 == 1` (`.seen`) |
| `test_scanner` | `test_scan_filesystem_directory` | `AssertionError: assert 0 == 2` |
| `test_migrate` | collection error | `ImportError: no pq wrapper available.` |
| `python_framework_codesign_test` | — | `Too many levels of symbolic links` |

### (a) Ingest-counter regression — **STILL PRESENT**

`grep -c "assert 0 == 1"` → 4. Now 4 failed / 8 passed (the file has grown to 12 tests; two
previously-failing tests in it were fixed by the runfiles change).

```
E           AssertionError: assert 0 == 1
E            +  where 0 = IngestCounters(seen=0, indexed=0, skipped=0, failed=0, placeholders=0, rejected=0, chunks_written=0, total_items=1, item_type='files', errors=[]).seen
```
At **`garage_python/tests/test_ingest_gateway.py:296`, `:564`, `:613`, `:642`** — the same four
lines as round 1. The assertions span `.seen`, `.indexed` and `.failed`; every counter stays 0
while `total_items=1`. Failing: `test_ingest_source_with_grpc_gateway`,
`test_stat_skipped_file_is_recorded_as_seen`, `test_no_chunks_file_is_recorded_as_seen`,
`test_unexpected_ingest_error_is_recorded_as_seen`.

### (b) Runfiles `__init__` gap — **FIXED**

No `AttributeError: module 'garage_rag' has no attribute ...` anywhere in the run.
`test_dedicated_rpcs`, `test_grpc_serialization`, `test_grpc_server`, `test_embed_xpc`,
`test_grpc_documents`, `test_ingest_xpc` and `test_embed_egress` all **PASS**. `39f9561`'s
dependency on `//garage_python/src/garage_rag` did the job.

### (c) libpq / psycopg — **mostly fixed; one genuine leftover, one bug unmasked**

Now passing: `test_cli_serve`, `test_egress_block`, `test_grpc_operations`, `test_mcp_install`,
`test_mcp_server`, `test_registry_dims`.

**`test_egress_block` passes in full.** The three subtests that failed in round 1 —
`test_add_source_refuses_before_touching_the_database`, `test_cli_add_source_refuses`,
`test_sync_refuses_a_declared_communication_source_with_cloud` — now pass. (The privacy invariants
themselves always passed; this restores the guard to being environment-independent.)

**`test_migrate` still fails**, but not because of the library: the *test file itself* imports
psycopg eagerly at **`garage_python/tests/test_migrate.py:4`** (`import psycopg`), before any
`garage_rag` code runs. `39f9561` removed eager imports from `cli`, `db/engine` and `db/migrate`,
but not from this test module.
```
garage_python/tests/test_migrate.py:4: in <module>
    import psycopg
E   ImportError: no pq wrapper available.
E   - couldn't import psycopg 'python' implementation: libpq library not found
```

**`test_scanner` now executes and reveals real failures** that the import error was previously
masking — 5 failed / 10 passed, none of them import-related:
```
garage_python/tests/test_scanner.py:72:  AssertionError: assert 0 == 2
garage_python/tests/test_scanner.py:92:  AssertionError
garage_python/tests/test_scanner.py:134: AssertionError
garage_python/tests/test_scanner.py:150: AssertionError
garage_python/tests/test_scanner.py:380: AssertionError
```
Distinct assertion shapes seen: `assert 0 == 1`, `assert 0 == 2`, `assert 1 >= 2`,
`assert 2 == 0`, `assert 2 == 3`. Failing: `test_scan_filesystem_directory`,
`test_scan_filesystem_exclude_prefixes_prune_subtrees`, `test_scan_git_repository`,
`test_scan_git_counts_what_ingest_walks`, `test_ingest_source_executes_scan_phase`.
`scan_filesystem(...)` returns `item_count == 0` where 2 is expected — the scanner counts nothing.
This looks related to the ingest-counter regression: both are "the pipeline ran but counted zero".

### (d) `python_framework_codesign_test` — **STILL FAILING, unchanged**

```
Verifying bundle: Python.framework
/var/folders/.../codesign_test.PcoHNy/stage/Python.framework: Too many levels of symbolic links
[FAIL] Bundle verification failed: Python.framework
Checked 0 Mach-O binaries: -1 passed, 1 failed
Error: No Mach-O binaries were found in target inputs
```
Identical to `ef303db`. Both defects stand: the symlink cycle from the tar staging at
**`bazel/codesign_test.bzl:114`**, and the negative pass count at
**`bazel/codesign_test.bzl:239`**.

### (e) Swift `AppStateTests` — **FIXED**

`//macapp/Tests/GarageAppUnitTests:GarageAppUnitTests` **PASSED** in 53.1s.
`testCombinedIngestProgressUsesPriorScanTotalsAcrossSources` (`("600") is not equal to ("1000")`)
is resolved. `GarageAppUITests` and `LlamaClientTests` also pass. New target `test_model_catalog`
passes.

## Round 2b summary

Fixed since round 1: the runfiles `__init__` gap, the Swift `AppStateTests` assertion, the
`runStartDate` warning, the xcarchive's unsigned framework (round 2), and the load error itself.
Test results went from 8 pass / 17 fail to **26 pass / 4 fail**.

Still open:
1. **Ingest counters stay at zero** — `test_ingest_gateway.py:296/564/613/642`, unchanged since
   round 1. The most substantive outstanding bug.
2. **Scanner counts nothing** — `test_scanner.py:72/92/134/150/380`, newly *visible* rather than
   newly broken. Probably the same root cause as (1).
3. **`test_migrate.py:4`** imports psycopg eagerly in the test module, so it still needs a system
   libpq.
4. **`python_framework_codesign_test`** — symlink cycle plus the negative-count arithmetic.

Unverified: the Developer ID transition on `//macapp/package:GarageApp` (step 4 skipped at the
user's request).

---

# Round 3 (4c067e4)

Run on 2026-09-23 on the same M4 (macOS 27.0 / 26A428, arm64), at PR head **`4c067e4`**, checked out
detached. It targets the four round-2b failures with `7cdbdc5` (the walker and scanner no longer prune
a source root under `Library/Caches`), `8735dff` (`test_migrate` no longer imports psycopg) and
`4c067e4` (codesign_test staging). The **Developer ID Application** certificate is now in the
login keychain (`E44E5D95… "Developer ID Application: Richard Penwell (DWVXMLB45Y)"`).
Nothing was pushed to `claude/adoring-ritchie-c084cj`. No notarize, installer, pkgbuild, install or
`xcarchive_open` target ran.

**No Keychain prompt appeared** ("codesign wants to access key") at any point. No `SecurityAgent`
process was up during the Developer ID signing actions, and every signing action completed
unattended.

Note on invocation: this Aspect CLI (launcher 2026.35.26 / CLI v2026.28.4) rejects bare Bazel flags
(`error: unexpected argument '--test_output' found`). Step 2 therefore ran as
`aspect test //... --bazel-flag=--test_output=errors`.

## Step 1: `aspect build //...` **PASS**

Exit 0, 9m35s. First-party warnings: the same three Swift 6 concurrency warnings as round 2b, and
nothing new:
```
macapp/Sources/GarageApp/Services/XPCServiceManager.swift:242:25: warning: reference to captured var 'manager' in concurrently-executing code; this is an error in the Swift 6 language mode
macapp/Sources/GarageApp/Services/XPCServiceManager.swift:245:25: warning: reference to captured var 'osLogStreamService' in concurrently-executing code; this is an error in the Swift 6 language mode
macapp/Sources/GarageIngestXPCService/main.swift:345:36: warning: capture of 'requester' with non-Sendable type 'NSXPCConnection?' in an isolated local function; this is an error in the Swift 6 language mode
```
There are also first-party *link* warnings, `ld: warning: duplicate -rpath '@executable_path/../Frameworks'
ignored` and `... '@loader_path/../Frameworks' ignored`. They come from linking
`macapp/Sources/GarageApp:GarageApp_bin` and both test bundles (`GarageAppUITests`,
`GarageAppUnitTests`). They are harmless but point to the rpath being added twice.
All other warnings (~1,900 lines) come from vendored Swift deps (swift-nio, grpc-swift,
swift-atomics, swift-collections). Bazel also warns `rules_swift@3.6.1` requested but `4.0.1`
resolved.

## Step 2: `aspect test //... --test_output=errors` **31 tests: 30 pass, 1 fail** (exit 3)

`Executed 31 out of 31 tests: 30 tests pass and 1 fails locally.` (Round 2b: 26 pass / 4 fail.)

| round-2b failure | now | detail |
|---|---|---|
| `test_ingest_gateway` | **PASS** | `12 passed`. Counters are no longer stuck at 0, so `7cdbdc5` fixed it. |
| `test_scanner` | **PASS** | `16 passed`. The scanner counts again. Same root cause, same fix. |
| `test_migrate` | **PASS** | `11 passed`. No libpq needed (`8735dff`). |
| `python_framework_codesign_test` | **FAIL** | New error, see below. |

Everything else passes too: all 26 other `garage_python/tests` targets, `//bazel:preset.update_test`,
and the Swift `GarageAppUnitTests` (47.7s), `GarageAppUITests` and `LlamaClientTests`. Caveat:
**`test_postgres` "PASSED" with `16 skipped`**. `GARAGE_TEST_DATABASE_URL` is not set in this
shell, so none of its real-SQL tests ran.

### `python_framework_codesign_test`: **still FAILING, with a different error**

The symlink loop and the `-1 passed` arithmetic are both gone. The staging now flattens the
framework, and codesign rejects it as ambiguous:
```
Verifying bundle: Python.framework
.../codesign_test.D92iq6/stage/Python.framework: bundle format is ambiguous (could be app or framework)
[FAIL] Bundle verification failed: Python.framework
.../stage/Python.framework/Python: bundle format is ambiguous (could be app or framework)
[FAIL] Python.framework/Python: codesign verification failed
[PASS] Python.framework/Versions/3.13/Python
[PASS] Python.framework/Versions/Current/Python
Checked 3 Mach-O binaries: 2 passed, 1 failed
Bundles: 1 failed verification
```
**Root cause (confirmed with `--sandbox_debug`):** `4c067e4` assumes the framework's own links
(`Versions/Current`, top-level `Python`/`Resources`/`Headers`) reach the test as relative symlinks.
That holds in `bazel-out`:
```
bazel-out/.../bin/ext/python/Python.framework/
  Headers   -> Versions/Current/Headers
  Python    -> Versions/Current/Python
  Resources -> Versions/Current/Resources
  Versions/Current -> 3.13
```
It does not hold inside the **darwin-sandbox**. There the tree artifact is laid out as real
directories, with every leaf file an **absolute** symlink into the execroot:
```
sandbox/darwin-sandbox/3468/.../runfiles/_main/ext/python/Python.framework/
  Headers/            (real dir)
  Resources/          (real dir)
  Python -> /Users/.../execroot/_main/bazel-out/.../Python.framework/Python    (absolute)
  Versions/Current/   (real dir, a duplicate of 3.13)
  Versions/3.13/Python -> /Users/.../Python.framework/Versions/3.13/Python    (absolute)
```
So `tar` has no relative links to keep. The new loop at **`bazel/codesign_test.bzl:127-135`** then
`cp -RL`s every absolute link, which turns top-level `Python` into a regular Mach-O and leaves
`Current`, `Resources` and `Headers` as real directories. That produces the "ambiguous" bundle.
Round 2b's "Too many levels of symbolic links" was the same sandbox layout, before the copy step.

Possible fixes (not applied): after staging, rebuild the versioned-framework links
(`Versions/Current -> <ver>`, and top-level `Python`/`Resources`/`Headers` -> `Versions/Current/…`).
Or stage from the real `bazel-out` tree, found by `readlink`ing any leaf and stripping its relative
suffix. Tagging the test `no-sandbox` would also sidestep it. The framework itself is signed
correctly: step 3 verifies it inside the app.

## Step 3: `aspect build //macapp/package:GarageApp` (Developer ID) **PASS**

Exit 0, 9m25s (a full rebuild under the Developer ID transition). No new first-party warnings: the
same three Swift warnings. Output is `bazel-bin/macapp/package/GarageApp.zip` (211 MB), extracted with
`ditto -x -k` to `Garage.app`.

**`codesign --verify --deep --strict --verbose=2 Garage.app`**: exit 0
```
Garage.app: valid on disk
Garage.app: satisfies its Designated Requirement
```

**`codesign -dvv Garage.app`**
```
Identifier=me.rickmark.garage-rag
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=75266 flags=0x10000(runtime) hashes=2345+3 location=embedded
Authority=Developer ID Application: Richard Penwell (DWVXMLB45Y)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Sep 23, 2026 at 7:36:21 AM
TeamIdentifier=DWVXMLB45Y
Runtime Version=27.0.0
```
The authority chain is as expected, with a secure timestamp, and **hardened runtime is on**
(`flags=0x10000(runtime)`).

Nested code. `--verify --deep --strict` exits 0 ("valid on disk / satisfies its Designated
Requirement") on each of these, and `-dvv` shows the same three-level Developer ID chain,
`TeamIdentifier=DWVXMLB45Y` and `flags=0x10000(runtime)` on each:

| path | Identifier | Format | Timestamp |
|---|---|---|---|
| `Contents/Frameworks/Python.framework` | `org.python.python` | bundle with Mach-O thin (arm64) | 7:36:19 AM |
| `Contents/MacOS/garage` | `garage` | Mach-O thin (arm64) | 7:36:18 AM |
| `Contents/MacOS/garage-mcp` | `garage-mcp` | Mach-O thin (arm64) | 7:36:15 AM |
| `Contents/XPCServices/GarageIngestXPCService.xpc` (spot check) | — | — | Developer ID, runtime |

So **round 1's blocker (b) is fixed**: `//macapp/package:GarageApp` does transition to, and sign
with, the Developer ID identity.

**`spctl --assess --type execute -vv Garage.app`**, recorded as-is: exit 0
```
Garage.app: accepted
source=Developer ID
origin=Developer ID Application: Richard Penwell (DWVXMLB45Y)
```
This is **not** the expected "Unnotarized Developer ID". The app is *not* notarized, though:
- `xcrun stapler validate`: "Garage.app does not have a ticket stapled to it."
- `syspolicy_check distribution Garage.app`: "App has failed one or more pre-distribution checks …
  **Notary Ticket Missing** … Severity: Fatal".
- `spctl --status`: assessments enabled.

The bundle carries `com.apple.provenance` but no `com.apple.quarantine`, because it was built and
unzipped locally. The likely explanation is that Gatekeeper's `spctl --assess` is lenient toward
non-quarantined, locally produced code on macOS 27. I have not verified this. Do not read "accepted"
as notarized: a downloaded copy would still need notarization.

## Step 4: architectures **arm64 only**

`macos_lipo_app` is declared with `arch = "arm64"` (`macapp/package/BUILD.bazel:13`), i.e. the
target thins to arm64 on purpose. It does not produce a universal binary. `lipo -archs` output:
```
arm64  MacOS/GarageApp
arm64  MacOS/garage
arm64  Frameworks/Python.framework/Versions/Current/Python
arm64  XPCServices/GarageEmbedXPCService.xpc/Contents/MacOS/GarageEmbedXPCService
arm64  XPCServices/GarageIngestXPCService.xpc/Contents/MacOS/GarageIngestXPCService
arm64  XPCServices/GarageMCPServerService.xpc/Contents/MacOS/GarageMCPServerService
arm64  XPCServices/GarageXPCService.xpc/Contents/MacOS/GarageXPCService
arm64  XPCServices/LlamaXPCService.xpc/Contents/MacOS/LlamaXPCService
arm64  XPCServices/ModelDownloadXPCService.xpc/Contents/MacOS/ModelDownloadXPCService
```
This matches what the target declares.

## Round 3 summary

**Fixed since round 2b:** the ingest counters (`test_ingest_gateway`), the scanner (`test_scanner`),
and `test_migrate`'s libpq dependency. The Developer ID packaging is now verified end-to-end:
signed, timestamped, hardened runtime, correct chain on the app, Python.framework, both CLIs and
the XPC services, arm64 as declared. Tests went from **26/4 to 30/1**.

**Still open:**
1. **`python_framework_codesign_test`**: "bundle format is ambiguous". The darwin sandbox
   materializes the framework with absolute per-file links and real `Current`/`Resources`/`Headers`
   directories, and the new `cp -RL` at `bazel/codesign_test.bzl:127-135` flattens top-level
   `Python`. Staging has to rebuild the framework's relative links, not assume they survive.
2. Minor: duplicate `-rpath` link warnings on `GarageApp_bin` and the two test bundles.
3. `test_postgres` was skipped entirely (no `GARAGE_TEST_DATABASE_URL`). Its SQL coverage was not
   exercised in this round.
4. `spctl` accepts the unnotarized build locally. This is expected to differ for a quarantined
   download, and notarization is still required for distribution.

---

# Round 4 (f558ef7)

Run on 2026-09-23 on the same M4 (macOS 27.0 / 26A428, arm64), at PR head **`f558ef7`**, checked out
detached. New since round 3: `36c19d5` (codesign_test rebuilds framework links), `b337487` (App Store
entitlements), `a171d4b` (xcarchive dSYMs, Team and Architectures) and `f558ef7` (test_scanner git
isolation, duplicate rpaths removed, docs).
Test database: Homebrew `postgresql@18` on `localhost:5432` (role `rickmark`, superuser, pgvector
0.8.6). Nothing pointed at the app's cluster on 14824.
**No Keychain prompt appeared** in any signing build: no `SecurityAgent` process came up during
steps 3–5. No notarize / installer / pkgbuild / install / `xcarchive_open` / upload tool ran, and
nothing was pushed to `claude/adoring-ritchie-c084cj`.

**Result: all six steps pass.**

## Step 1: `aspect build //...` **PASS**

Exit 0, 38s. Mostly action-cache hits (`14564 action cache hit, 44 darwin-sandbox, 11 local`).
Cached compiles do not replay their diagnostics, so this run printed **zero** `warning:` lines. The
three Swift 6 concurrency warnings are still there, because their sources did not change: step 3's
fresh App Store build re-emitted them verbatim (`XPCServiceManager.swift:242:25`, `:245:25`,
`GarageIngestXPCService/main.swift:345:36`). No new first-party warnings.

**`ld: warning: duplicate -rpath` is gone.** The build log has 0 occurrences. Because the relinks
could also have been cache hits, I checked the link command lines directly with
`bazel aquery --output=jsonproto` over every `ObjcLink` action in the app and both test bundles.
No action repeats an rpath:
```
GarageApp_bin rpaths: 6 dups: {}
Garage{Ingest,MCPServer,Embed}XPCService_bin, GarageXPCService_bin, ModelDownloadXPCService_bin,
  LlamaXPCService_bin, PythonXPCService_framework_bin     rpaths: 5 dups: {}   (each)
GarageAppUnitTests / GarageAppUITests __test_bundle_bin  rpaths: 7 dups: {}   (each)
```
(Before `f558ef7`, `GarageApp_lib`'s linkopts added `@executable_path/../Frameworks` and
`@loader_path/../Frameworks` on top of rules_apple's own.)

## Step 2: `GARAGE_TEST_DATABASE_URL=… aspect test //... --bazel-flag=--test_output=errors` **PASS**

Exit 0, 60s. **`Executed 31 out of 31 tests: 31 tests pass.`** No failing targets.

- **`python_framework_codesign_test` PASSES under the default darwin-sandbox.** The target has no
  `no-sandbox`/`local` tags, and the progress lines show `Testing //ext/python:python_framework_codesign_test; … darwin-sandbox`.
  ```
  Verifying bundle: Python.framework
  .../stage/Python.framework: valid on disk
  .../stage/Python.framework: satisfies its Designated Requirement
  [PASS] Bundle valid: Python.framework
  [PASS] Python.framework/Versions/3.13/Python
  Checked 1 Mach-O binaries: 1 passed, 0 failed
  ```
  Only one Mach-O is counted now (round 3: 3) because top-level `Python` and `Versions/Current` are
  links again, not copies.
- **`test_postgres` ran, not skipped:** `============ 16 passed in 1.22s ============`. The
  `.bazelrc` `--test_env` passthrough works.

## Step 3: `aspect build //macapp:GarageStore.app` **PASS**

Exit 0, 7m49s. Note: `bazel-bin/macapp/GarageStore.app` is a 934-byte launcher script (it `exec`s
the app binary from runfiles), not a bundle. The signed bundle is the transitioned
`bazel-out/darwin_arm64-fastbuild-macos-arm64-min14.0-ST-a379604bb3e5/bin/macapp/Sources/GarageApp/GarageApp.zip`,
listed in the launcher's runfiles manifest, and was extracted with `ditto -x -k`.

**App entitlements** (`codesign -d --entitlements -`). Both new keys are present with the expected values:
```
"com.apple.application-identifier"    => "DWVXMLB45Y.me.rickmark.garage-rag"
"com.apple.developer.team-identifier" => "DWVXMLB45Y"
"com.apple.security.app-sandbox" => true
"com.apple.security.application-groups" => ["DWVXMLB45Y.group.me.rickmark.garage-rag"]
"com.apple.security.cs.disable-library-validation" => true
"com.apple.security.files.bookmarks.app-scope" => true
"com.apple.security.files.user-selected.read-only" => true
"com.apple.security.files.user-selected.read-write" => true
"com.apple.security.network.client" => true
"com.apple.security.network.server" => true
```

**XPC services.** None of the six carries `com.apple.security.inherit`, and each keeps
`com.apple.security.app-sandbox => true`. Each also has the app group, `disable-library-validation`,
bookmarks and user-selected files, and `network.client`:

| XPC service | inherit | app-sandbox | network.server |
|---|---|---|---|
| GarageEmbedXPCService | absent | true | — |
| GarageIngestXPCService | absent | true | — |
| GarageMCPServerService | absent | true | true |
| GarageXPCService | absent | true | true |
| LlamaXPCService | absent | true | true |
| ModelDownloadXPCService | absent | true | — |

**`codesign --verify --deep --strict --verbose=2`**: exit 0, `valid on disk` / `satisfies its
Designated Requirement`. `-dvv`: `Apple Distribution: Richard Penwell (DWVXMLB45Y)` → Apple
Worldwide Developer Relations Certification Authority → Apple Root CA, `TeamIdentifier=DWVXMLB45Y`,
`flags=0x10000(runtime)`.

## Step 4: `aspect build //macapp:GarageStore.xcarchive` **PASS**

Exit 0, 19s. Output is
`bazel-out/darwin_arm64-fastbuild-ST-37fe811ccc69/bin/macapp/_GarageStore_xcarchive_raw/Garage.xcarchive`,
from `bazel cquery --output=files`. It is in a transitioned config, so `bazel-bin/macapp` has no
`.xcarchive`.

**`dSYMs/`** contains 8 bundles, all arm64:
```
Garage.app.dSYM                    EC9BDFFF-02A5-3C8F-B24A-9F4963381D6C
GarageEmbedXPCService.xpc.dSYM     50796926-…    GarageIngestXPCService.xpc.dSYM  AAD3E4B8-…
GarageMCPServerService.xpc.dSYM    2C6A5DE8-…    GarageXPCService.xpc.dSYM        BB8BD6B0-…
LlamaXPCService.xpc.dSYM           6253AF81-…    ModelDownloadXPCService.xpc.dSYM 68080D03-…
PythonXPCService.framework.dSYM    BD4D5425-…
```
`Garage.app.dSYM`'s UUID **matches** the archived `Contents/MacOS/GarageApp`
(`EC9BDFFF-02A5-3C8F-B24A-9F4963381D6C`), so symbolication will line up.

**`plutil -p Info.plist`**:
```
"ApplicationProperties" => {
  "ApplicationPath" => "Applications/Garage.app"
  "Architectures" => [ 0 => "arm64" ]
  "CFBundleIdentifier" => "me.rickmark.garage-rag"
  "CFBundleShortVersionString" => "0.9"
  "CFBundleVersion" => "217"
  "SigningIdentity" => "Apple Distribution: Richard Penwell (DWVXMLB45Y)"
  "Team" => "DWVXMLB45Y"
}
"ArchiveVersion" => 2   "Name" => "Garage"   "SchemeName" => "Garage"
```

**`codesign --verify --deep --strict`** on `Products/Applications/Garage.app`: exit 0, valid, and it
satisfies its DR. Apple Distribution chain, runtime flag set.

## Step 5: `aspect build //macapp/package:GarageApp` (Developer ID) **PASS, unchanged**

Exit 0, 2m01s. `bazel-bin/macapp/package/GarageApp.zip` was extracted with `ditto`.
- `codesign --verify --deep --strict --verbose=2 Garage.app`: exit 0, valid, and it satisfies its DR.
- `codesign -dvv`: `Developer ID Application: Richard Penwell (DWVXMLB45Y)` → Developer ID
  Certification Authority → Apple Root CA, `TeamIdentifier=DWVXMLB45Y`,
  `flags=0x10000(runtime)`, timestamped, `Mach-O thin (arm64)`.
- **Entitlements are unchanged from round 3: none.** `codesign -d --entitlements -` prints only
  the `Executable=` line for the app and for all six XPC services, exactly as for the round-3
  (`4c067e4`) Developer ID app. The store keys did not leak into it.

  Observation, not tested at runtime: the Developer ID app therefore has no
  `com.apple.security.application-groups` and no `cs.disable-library-validation`. If any
  code path relies on the `group.me.rickmark.garage-rag` container, or loads a library signed by a
  different team under hardened runtime, it would behave differently from the Store build. That
  is worth a GUI smoke test of the Developer ID build.

## Step 6: `pytest` in `garage_python/.venv` **PASS**

`.venv` already existed (Python 3.14.2), so `uv sync` was skipped. My normal git config was left in
place, and it is the case that used to hang: global `commit.gpgsign=true` with `gpg.format=ssh` via
Secretive (Touch ID). The run was wrapped in a 900s `alarm` guard (macOS has no `timeout(1)`).
```
GARAGE_TEST_DATABASE_URL=postgresql://localhost:5432/postgres .venv/bin/python -m pytest -q
597 passed in 25.72s          (exit 0, 28s wall)
```
**test_scanner did not hang** and no Touch ID prompt appeared, so the git-config isolation works.
Nothing was skipped, which means the Postgres-backed tests ran here too.

## Round 4 summary

Every item from round 3 is closed:
- **`python_framework_codesign_test` passes in the darwin sandbox** (`36c19d5`).
- **Duplicate `-rpath` link warnings are gone**, confirmed on the link command lines (`f558ef7`).
- **`test_postgres` runs for real:** 16 passed under Bazel, and everything passes under the venv.

The App Store fixes from the M3's round 3 check out on this machine:
- The app gains `application-identifier` and `team-identifier`.
- The XPC services lose `inherit` and stay sandboxed.
- The xcarchive has matching dSYMs, `Team` and `Architectures`.

The Developer ID build is unaffected. **Bazel: 31/31. venv pytest: 597/597.**

Still open (not regressions):
1. The three Swift 6 concurrency warnings (`XPCServiceManager.swift:242/245`,
   `GarageIngestXPCService/main.swift:345`).
2. The Developer ID app ships with no entitlements at all (see step 5). Probably intended, but
   worth a runtime check.
3. Unchanged from round 3: the Developer ID build is not notarized, by design.

---

# App group data folder (`claude/app-group-data`)

Branch **`claude/app-group-data`**, commit **`904ab61`**, based on the PR head **`f558ef7`**. It is
pushed for review and for folding into PR #15; nothing went to `claude/adoring-ritchie-c084cj`.
The change gives the App Store and Developer ID builds one shared data folder.

## 1. Where the data lives

The data is `pgdata/` (the Postgres cluster), `models/`, `logs/` and `garage.json`, all in one
folder.

| build | before | now |
|---|---|---|
| Developer ID (not sandboxed) | `~/Library/Application Support/GarageApp/` | `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/` |
| App Store (sandboxed) | `~/Library/Containers/me.rickmark.garage-rag/Data/Library/Application Support/GarageApp/` | same group path as above |
| locally signed / tests (not entitled) | `~/Library/Application Support/GarageApp/` | unchanged |

Resolution lives in the new `GarageAppGroup` (`macapp/Sources/PythonXPCService/GarageAppGroup.swift`,
in `PythonXPCService_protocol`). It returns the group path only when the running process actually
carries the group entitlement (`SecTaskCopyValueForEntitlement`). Otherwise it returns the
per-user path, so unentitled builds never touch a group container. On macOS 15+ that can prompt.
`Paths.appSupportDir`, `ModelDownloaderEngine.defaultModelsDirectory` and `GarageFileLogger` all
use it.

Fixed on the way: `GarageFileLogger.appGroupIdentifier` was `group.me.rickmark.garage-rag`, which
has no team prefix and did not match the entitlement. That is why a stray
`~/Library/Group Containers/group.me.rickmark.garage-rag/logs/` exists on this Mac. It is now
`GarageAppGroup.identifier`.

## 2. Entitlements per config

| binary | App Store (`is_store`) | Developer ID (`is_developer_id`) | local / default |
|---|---|---|---|
| `Garage.app` | unchanged (sandbox, app-id, team-id, group, …) | **new:** `com.apple.security.application-groups = [DWVXMLB45Y.group.me.rickmark.garage-rag]` only | none |
| 6 XPC services | unchanged (sandbox, group, …) | **new:** the same group, only | none |
| `garage` / `garage-mcp` launchers | unchanged (`GarageServer.entitlements`: sandbox + inherit) | none (unchanged; they never touch the folder) | none |

The Developer ID entitlements file is `macapp/externals/GarageAppGroup.entitlements`. The seven
`entitlements = select(...)` blocks gained an `"//bazel:is_developer_id"` arm; the package's
Developer ID transition sets `signing_certificate_name`, which selects it.

**No provisioning profile is needed for Developer ID.** A group ID that begins with the signing
team's ID (`DWVXMLB45Y.`, the macOS form) is valid without a profile. A profile is required only for
iOS-style `group.`-prefixed IDs, and the Store profile's `DWVXMLB45Y.*` wildcard also covers this ID.

**Packaging bug found and fixed (`bazel/lipo.bzl`).** Adding the entitlement at first changed
nothing in the packaged app. rules_apple *had* signed it (the pre-lipo app carried the group), but
`macos_lipo_app`'s re-sign dropped it, for two reasons:
1. Nested `.xpc`/`.framework` bundles were re-signed without `--entitlements`, which re-signs their
   main executable bare.
2. The app was signed with the entitlements of `Contents/MacOS/<bundle name>` = `Garage`, which does
   not exist. The script fell back to whichever file `os.listdir` returned first (`garage-mcp`,
   which has none).

Bundles are now signed with the entitlements of their `CFBundleExecutable`. This is also why rounds
3 and 4 showed the Developer ID app with **no entitlements at all**. It was a bug, not intent.

## 3. Migrating an existing install

At launch, `GarageDataMigration.runAtLaunch()` runs as the first step of `AppState.launch()`, before
garage.json is re-read, the XPC services start streaming, or Postgres starts. It moves the build's own
old folder (Developer ID: `~/Library/Application Support/GarageApp`; Store: its container's) into the
group folder. It runs only in an entitled, non-test process. Rules:
- **Rename only.** It never copies, deletes or overwrites.
  - An entry moves when the group folder has nothing by that name, or only an empty directory
    (an XPC service may have created `models/` or `logs/` first).
  - Anything already present there stays in the old folder and is logged.
- **Two clusters:** the first build launched moves its `pgdata`. The other build's old cluster is
  left in place untouched, and a warning is logged. There is no merge.
- **Running postmaster:** if `pgdata/postmaster.pid` names a live process, `pgdata` is not moved this
  launch. A stale pid file (after a crash) does not block the move.
- **Emptied old folder:** it is replaced by a symlink to the group folder, so saved paths and older
  builds still resolve. The move is idempotent, and a second run is a no-op.
- **Partial or failed move:** each entry is independent. Failures are logged (`GarageDataMigration`
  category) and retried on the next launch. Two guards in `PostgresService` keep a partial move safe:
  - `ensureInitialized()` **refuses to `initdb`** while the old folder still holds
    `pgdata/PG_VERSION` and the group folder does not. The app shows "The database is still in … and
    could not be moved … Quit every copy of Garage, then open it again", instead of creating an
    empty cluster that would hide the corpus.
  - `postgresPassword()` **refuses to generate a new password** when a cluster exists but this
    build's Keychain lookup finds no item. Before, it would silently save a new one and lock itself
    out. This is the expected failure if the Store build opens a cluster the Developer ID build
    created and the sandboxed Keychain lookup can't see the other build's item. It is untested
    (see 5).

This Mac currently has **two** clusters: Developer ID `~/Library/Application Support/GarageApp/pgdata`
(299 MB, Sep 21, plus 774 MB of models) and Store `…/Containers/me.rickmark.garage-rag/…/pgdata`
(64 MB, Sep 20). Whichever build launches first will move its own cluster into the group folder,
and the other will be left where it is.

## 4. Launchers and the Python side

- **`garage` / `garage-mcp`** (`GarageLauncher`) never used the data folder. They read the password
  from the Keychain (`com.rickmark.garage.postgres`), connect to `localhost:14824`, and find config
  via `--config`, `./garage.json` in *their* working directory, or `~/.garage.json`. Unchanged.
- **`GARAGE_MODEL_MANIFEST`** points into the app bundle (`Paths.modelsJSON`, and `Launcher.swift:122`
  for the launchers), not the data folder. Unchanged.
- **gRPC server `./garage.json`**: the working directory is `Paths.garageWorkingDirectory` =
  `Paths.appSupportDir`, now the group folder, passed as `GARAGE_WORKING_DIRECTORY` to the XPC service.
  That service carries the group entitlement in both configs, and `garage.json` moves with the folder.
- **Models:** files are found by name relative to the models folder (`download_file`); no saved
  absolute paths were found. The old-path symlink covers any that exist.

## 5. What was verified, and what was not

- `tools/swiftcheck/check.sh`: 110 files, pass.
- `aspect build //:macapp`, `//...`, `//macapp:GarageStore.app`, `//macapp/package:GarageApp`: all
  exit 0. No new warnings (the same three Swift 6 ones).
- `aspect test //macapp/Tests/...`: 3/3 targets pass. `GarageAppUnitTests` ran 228 tests with 0
  failures, including 10 new `GarageDataMigrationTests` covering these cases:
  - moves everything and links the old folder;
  - a second run is a no-op;
  - it never overwrites an existing cluster;
  - it replaces empty directories;
  - it keeps pgdata while a postmaster runs;
  - a stale pid file does not block the move;
  - no old folder, and the same folder, are no-ops;
  - the team-prefixed ID, and an unentitled test host.
- **Developer ID package** (after the lipo fix): `codesign --verify --deep --strict` is valid. The
  chain is Developer ID Application → Developer ID CA → Apple Root CA, `TeamIdentifier=DWVXMLB45Y`,
  `flags=0x10000(runtime)`, arm64. Entitlement dump: `Garage.app` and all six XPC services show
  `{"com.apple.security.application-groups":["DWVXMLB45Y.group.me.rickmark.garage-rag"]}`;
  `garage`, `garage-mcp`, `Python.framework` and `PythonXPCService.framework` show none.
- **App Store app:** verifies under Apple Distribution. The app (10 keys) and six XPC services
  (7–8 keys) all carry the same team-prefixed group plus `app-sandbox = true`, unchanged from round 4.
- **Neither app was launched.** First launch performs the migration on the real corpus, so it
  waits for an explicit go-ahead. Still unverified at runtime:
  - the move itself;
  - Postgres (a child of the Developer ID app) starting from the group container;
  - whether a Developer ID app with a team-prefixed group launches without a prompt on macOS 27;
  - whether each build can read the other's Keychain item.

  Before that first launch: quit Garage and back up both old folders (`ditto`) or `pg_dump`, then
  launch **one** build, check the logs, and only then the other.
