# M3 runtime validation — `claude/adoring-ritchie-c084cj` @ `ef303db`

Machine: Apple M3 Max, 128 GB · macOS 27.0 (26A428) · Xcode 27.0 (27A266a) · Swift 6.4
Validated commit: `ef303db` ("Fix combined batch progress; let garage-mcp answer before Postgres is up")
Ancestors confirmed present: `57a71ac`, `7192da5`, `6073b9b`.

| Step | Result |
|---|---|
| 1. `aspect build //:macapp` | **PASS** |
| 2. Migrations 008 / 009, twice each | **PASS** |
| 3. `garage search` via the bundled CLI | **PASS** (see the `hnsw_bq` note) |
| 4. `garage-mcp` answers before Postgres is up | **FAIL** |
| 5. `garage mcp-install` registration contents | **PASS** |

Not run, per instructions: notarize, the installer, any install target, `xcarchive_open`.

---

## 1. Build — PASS

`aspect build //:macapp` → exit 0, 386.5 s, 124 actions, "Build completed successfully".
No signing failure, so `--config=adhoc` was not needed.

## 2. Migrations — PASS

Run against a **scratch cluster** (Homebrew PostgreSQL 18.4, pgvector 0.8.6), not the app's own
database. The task offered either; the scratch path was taken because the app cluster's password is
Keychain-held and this session cannot grant a Keychain ACL (no interactive approval is available,
and that read is blocked by policy here). Using a scratch cluster also avoids mutating the real
corpus. Migrations were applied with the **bundled** `psql` and the **bundled** schema in
`Garage.app/Contents/Resources/schema`, which does ship 008 and 009.

Note that `57a71ac` also removed `expected_items` from `003_core.sql`, so a freshly-created 001–007
database never has that column and `008`'s `DROP COLUMN IF EXISTS` would be a no-op. To exercise the
real upgrade path the column was restored by hand and three sources were seeded to cover the
branches in the data migration.

### 008_source_scan.sql

First application:

```
ALTER TABLE / ALTER TABLE / ALTER TABLE / UPDATE 2 / UPDATE 2 / ALTER TABLE
[exit=0]
```

Second application — clean no-op:

```
NOTICE:  column "scan_item_type" of relation "sources" already exists, skipping
NOTICE:  column "scan_details" of relation "sources" already exists, skipping
NOTICE:  column "scanned_at" of relation "sources" already exists, skipping
UPDATE 0
UPDATE 0
NOTICE:  column "expected_items" of relation "sources" does not exist, skipping
[exit=0]
```

`\d sources` is **byte-identical** before and after the second run. Only skip NOTICEs, both UPDATEs
match zero rows, exit 0.

### 009_model_distance.sql

First application: `ALTER TABLE` + `DO`, exit 0.
Second application: `NOTICE: column "distance" ... already exists, skipping`, `ALTER TABLE`, `DO`,
exit 0. `\d embedding_models` **byte-identical** across the two runs.

A model registered before the column existed correctly defaults to cosine, and the constraint is
enforced:

```
     slug     | storage_kind | index_kind | distance
 legacy-model | vector       | hnsw       | cosine

ERROR:  new row for relation "embedding_models" violates check constraint
        "embedding_models_distance_check"
```

### Resulting schema

`\d sources` — added, and `expected_items` gone:

```
 expected_elements      | bigint                   | not null | 0
 config                 | jsonb                    | not null | '{}'::jsonb
 created_at             | timestamp with time zone | not null | now()
 scan_item_type         | text                     |          |
 scan_details           | jsonb                    | not null | '{}'::jsonb
 scanned_at             | timestamp with time zone |          |
```

`\d embedding_models` — added:

```
 distance     | text | not null | 'cosine'::text
Check constraints:
    "embedding_models_distance_check" CHECK (distance = ANY (ARRAY['cosine','l2','inner_product']))
```

### Scan data moved out of `config`

| slug | before (`config`) | after (`config`) | `scan_item_type` | `scan_details` | `scanned_at` |
|---|---|---|---|---|---|
| `docs` | `include_code`, `item_type`, `scan_details`, `scanned_at` | `{"include_code": false}` | `documents` | `{"md": 80, "pdf": 40}` | `2026-09-21 07:13:20.5-07` |
| `mail` | `{"include_code": true}` | unchanged | `NULL` | `{}` | `NULL` |
| `odd` | `item_type` + malformed `scanned_at`/`scan_details` | `{}` | `messages` | `{}` | `NULL` |

All three assertions pass: no scan keys remain in any `config`, the user-facing `include_code`
setting survives, and the `jsonb_typeof` guards correctly skip the malformed `scanned_at`
(a string) and `scan_details` (a string) on the `odd` row while still carrying over its
`item_type`. `expected_items` is dropped.

## 3. `garage search` — PASS

Through `Garage.app/Contents/MacOS/garage`, against a scratch corpus of two documents embedded with
the 384-dim `mxbai-embed-xsmall` model served by the app's `LlamaXPCService`.

```
$ garage search "what ruins heat pump efficiency"
1. Heat pumps in cold climates (document/authored, both, score 0.0328)
2. Sourdough starter (document/authored, vector, score 0.0161)
[exit=0]

$ garage search "wild yeast culture"
1. Sourdough starter (document/authored, both, score 0.0328)
2. Heat pumps in cold climates (document/authored, vector, score 0.0161)
[exit=0]
```

Both rank the right document first, and the `both` marker shows RRF fusing the vector and FTS
engines. Registration now prints the new column: `registered embed: 384-dim -> vector(384),
index=hnsw, distance=cosine, table=emb_embed`.

### On "a model with a binary-quantized table (`storage_kind` bit)"

There is no such thing to look for — `embedding_models_storage_check` still allows only
`('vector','halfvec')`, and `search/hybrid.py:202` keys the two-stage path on
**`index_kind == "hnsw_bq"`**, not on `storage_kind`. The embedding column stays full-width and
unindexed; the HNSW index is built on `binary_quantize(embedding)::bit(d)`.

No `hnsw_bq` model was registered, so one was created to exercise `6073b9b`. Registering an
8192-dim model picks the path correctly:

```
WARNING bigmodel is 8192-dim and not MRL-capable; indexing a binary quantization
        and re-ranking on exact cosine distance at query time
registered bigmodel: 8192-dim -> vector(8192), index=hnsw_bq, distance=cosine
"emb_bigmodel_hnsw_bq" hnsw ((binary_quantize(embedding)::bit(8192)) bit_hamming_ops)
```

With 3000 synthetic rows, stage one's `ORDER BY binary_quantize(e.embedding)::bit(8192) <~> ...`
**does** match the index — the expression, operator class and width all line up:

| LIMIT | plan | time | rows returned |
|---|---|---|---|
| 10 | `Index Scan using emb_bigmodel_hnsw_bq` | 0.78 ms | 10 |
| 100 | `Index Scan using emb_bigmodel_hnsw_bq` | 3.63 ms | 100 |
| 800 (`CANDIDATE_DEPTH * BQ_OVERFETCH`) | **`Seq Scan`** | 57.6 ms | 800 |
| 800, `enable_seqscan=off` | `Index Scan` | 3.51 ms | **330** |
| 800, `enable_seqscan=off`, `hnsw.ef_search=800` | `Index Scan` | 2.88 ms | **330** |

Two things worth a second look, neither of which blocks this PR:

1. At the production depth of 800 the planner prefers a sequential scan (57.6 ms) even though the
   index would serve it in ~3.5 ms — on this table the over-fetch depth defeats the index the
   commit added.
2. When the index *is* forced, it returns only 330 of the 800 requested rows, and raising
   `hnsw.ef_search` to 800 does not change that. Stage two would then re-rank a smaller candidate
   set than intended.

**Caveat:** these were random `±1` vectors, which is close to a worst case for binary quantization
(Hamming distances all cluster near d/2, so the HNSW graph degenerates), and 3000 rows is small —
sequential scan cost grows linearly while HNSW does not, so the planner may well flip on a real
corpus. This should be re-measured with a genuine >4000-dim model over real data before being
treated as a defect.

## 4. `garage-mcp` answering before Postgres — FAIL

Garage.app was quit and its cluster stopped first; `14824` had zero listeners and `8790` was down
at the start of every run below.

**Cold (app down), instrumented:**

```
[   0.01s ERR] Starting Garage…
=== COLD initialize: NO RESPONSE within 240s ===
```

**Cold, first attempt (read to completion):** no response; the process ran **537 s** and then died
with a database error:

```
Starting Garage…
INFO garage_rag.mcp: garage-rag MCP server starting (transport=stdio)
INFO garage_rag.mcp: database connection: postgresql+psycopg://rickmark:***@localhost:14824/garage-rag
Error running garage_rag.mcp_server.server.main: Traceback (most recent call last):
  File ".../sqlalchemy/engine/base.py", line 144, in __init__
    self._dbapi_connection = engine.raw_connection()
```

**Warm (Garage.app running, Postgres up on 14824, llama up on 8790):** no `initialize` response and
**no output at all on either stream** within 60 s, process still alive.

The launch half of the change does work — a cold `garage-mcp` starts Garage.app (observed pid), and
Postgres and the llama engine both come up as a result. But `stdout` stayed at **0 bytes**
throughout, including after Postgres was fully up, so nothing ever answered the handshake. A stdio
MCP client would hang rather than see a server.

Because `initialize` never completed, the follow-on `tools/call` of a search tool could not be
attempted.

## 5. `garage mcp-install` — PASS

`garage mcp-install --path <scratch> --stdio --yes` → exit 0. Written file, in full:

```json
{
  "mcpServers": {
    "garage-rag": {
      "command": "/…/Garage.app/Contents/MacOS/garage-mcp",
      "args": []
    }
  }
}
```

- command is absolute — **PASS**
- command is the bundled `Contents/MacOS/garage-mcp` — **PASS**
- the path exists on disk — **PASS**
- no `GARAGE_DATABASE_URL` — **PASS** (there is no `env` block at all)
- no password, `PGPASSWORD`, or `postgresql://` DSN anywhere in the file — **PASS**

## Environment left behind

Nothing was fixed and nothing was pushed to `claude/adoring-ritchie-c084cj`. Both scratch databases
(`garage_m3_mig`, `garage_m3_search`) were dropped; the app's own database was never written to.
Garage.app is quit and its cluster stopped — `14824`, `8787` and `8790` all have zero listeners.

---

# Re-check (80c11fc)

Re-run on the current head `80c11fc` after `62edda7` ("Let stdio garage-mcp answer initialize
before touching the database"). Same machine: Apple M3 Max, 128 GB · macOS 27.0 (26A428) ·
Xcode 27.0 (27A266a) · Swift 6.4.

| Step | Result |
|---|---|
| 1. `aspect build //:macapp` | **PASS** |
| 2. Dead DB port: initialize, then `tools/call` | **PASS** |
| 3. Live scratch cluster: initialize, then `tools/call` | **PASS** |
| 4. Keychain prompt with `GARAGE_DATABASE_URL` unset | **No prompt** |

`62edda7` fixes the step 4 failure from the first report. `garage-mcp` now answers `initialize`
in every configuration tried, and a dead database surfaces as a tool error rather than a hang.

Not run, per instructions: notarize, the installer, any install target, `xcarchive_open`.

## 1. Build — PASS

`aspect build //:macapp` → exit 0, 386.4 s, "Build completed successfully".

## 2. Nothing listening at the URL's port — PASS

`GARAGE_DATABASE_URL=postgresql+psycopg://nobody@localhost:15999/nodb`, with zero listeners on
15999. Setting the variable does make the launcher skip both the Keychain read and the app launch:
there is no `Starting Garage…` line and Garage.app was not started.

```
INITIALIZE: OK  (5.39 s)
  -> {"jsonrpc":"2.0","id":1,"result":{"capabilities":{...},"protocolVersion":"2025-06-18",
      "serverInfo":{"name":"garage-rag",...}}}
tools: ['rag_search', 'rag_get_document', 'rag_list_sources', 'rag_list_authors',
        'rag_stats', 'rag_ask', 'rag_generate']
TOOLS/CALL: responded  (0.11 s)
  isError: True
  content: Error executing tool rag_search
process alive after call: True
```

The start-up log names the database without querying it, which is the change:

```
INFO garage_rag.mcp: garage-rag MCP server starting (transport=stdio)
INFO garage_rag.mcp: database connection: postgresql+psycopg://nobody@localhost:15999/nodb
```

The failure is a clean JSON-RPC tool error — `isError: true`, answered in 0.11 s, server still
alive and able to take more requests. No hang and no crash. The underlying
`sqlalchemy ... engine.raw_connection()` traceback stays on stderr.

One small note: the text the client receives is only `Error executing tool rag_search`. It does not
say the database is unreachable, so from an MCP client the cause is not diagnosable without the
server's stderr. Worth considering a message that names the connection failure.

## 3. Scratch cluster up — PASS

`GARAGE_DATABASE_URL` pointing at a scratch database on the Homebrew cluster, migrated to 009, with
the 384-dim `mxbai-embed-xsmall` model registered as default and one document ingested and
embedded (the app was running only to provide `LlamaXPCService` on 8790 for query embedding).

```
INITIALIZE (live DB): OK  (3.34 s)
TOOLS/CALL rag_search: responded  (0.18 s)
  isError: False
  structured: {"query": "what ruins heat pump efficiency", "mode": "hybrid", "model": "embed",
               "count": 1, "hits": [{"chunk_id": 1, "document_id": 1,
               "title": "Heat pumps in cold climates", "corpus_class": "document",
               "trust_tier": "authored", "matched_by": "both", "score": 0.032787, ...}]}
TOOLS/CALL rag_stats: (0.02 s)
  isError: False | {"documents": 1, "chunks": 1, "authors": 0, "placeholders_pending": 0,
                    "by_class_and_trust": [...], "models": [{"slug": "embed", "dims": 384, ...}]}
```

`matched_by: "both"` shows RRF fusing the vector and FTS engines, and the score matches what the
CLI returns for the same query.

## 4. Keychain prompt with `GARAGE_DATABASE_URL` unset — no prompt

Recorded only; nothing was answered or approved.

**No Keychain prompt appears.** Measured by comparing the set of `SecurityAgent` processes
immediately before and during each run:

- **Warm** (Garage.app running, its Postgres up on 14824): `initialize` answered at **3.15 s**, and
  `SecurityAgent` was absent both before and during — an identical (empty) set. There is no
  `Starting Garage…` line, because the launcher sees the app already running.
- **Cold-ish** (app running but its Postgres not yet up): `Starting Garage…` at 0.01 s, then a
  22.8 s gap, then `initialize` answered at **22.81 s**. The gap is the launcher waiting for
  Postgres to come up, not a prompt: the `SecurityAgent` pid present before that run was unchanged
  during it and exited afterwards on its own.

In both cases the bundled binary read the password silently and logged
`postgresql+psycopg://rickmark:***@localhost:14824/garage-rag`, which is expected — `garage-mcp`
ships inside the same signed bundle as the app, so it is already on the Keychain item's ACL.

This is process-level evidence. Screen capture is not available to this session, so a dialog that
somehow left no `SecurityAgent` process behind would not have been seen; nothing in the observed
behaviour suggests one.

## Environment left behind

`claude/adoring-ritchie-c084cj` unchanged. The scratch database `garage_recheck` was dropped and no
`garage*` databases remain on the Homebrew cluster; the app's own database was never written to.
Garage.app is quit and its cluster stopped — 14824, 8787 and 8790 all have zero listeners.

---

# test_postgres (db263ef)

`garage_python/tests/test_postgres.py` run against this Mac's Homebrew development server, on
`db263ef` ("Test against a development Postgres server; document it"). Same machine as the sections
above: Apple M3 Max, 128 GB · macOS 27.0 (26A428).

| Step | Result |
|---|---|
| 2. Under Bazel (`--test_env` passthrough + bundled libpq) | **PASS** — 16 passed |
| 3. Through the venv's pytest | **PASS** — 16 passed |
| 4. No `garage_test_*` databases left behind | **PASS** — none |

## Server

| | |
|---|---|
| Server | PostgreSQL **18.4** (Homebrew) on aarch64-apple-darwin25.4.0, compiled by Apple clang 21.0.0 |
| pgvector | **0.8.6** |
| Port | 5432 (Homebrew service) |
| URL form | `postgresql://localhost:5432/postgres` — exactly the form CLAUDE.md documents |
| Role | the login user, confirmed `usesuper = t`, via local trust auth |

The URL carries **no password and no credential of any kind**: Homebrew's cluster uses local trust
auth for the login user, which is also the superuser the test needs in order to create a database
and install pgvector (not a trusted extension). Nothing secret is recorded here or written to any
tracked file.

The app's own cluster on port 14824 was **not** used and was down (zero listeners) for the whole
run, per the "never point it at the app's own cluster" rule.

## 2. Under Bazel — PASS

```
GARAGE_TEST_DATABASE_URL=postgresql://localhost:5432/postgres \
  aspect test //garage_python/tests:test_postgres --test_output=errors

//garage_python/tests:test_postgres      PASSED in 2.5s
Executed 1 out of 1 test: 1 test passes.
```

The test log shows the tests actually executing rather than skipping — `16 passed in 1.04s`,
covering the migrations and 008's data move, the per-model DDL for each distance metric
(`vector_cosine_ops`, `vector_l2_ops`, `vector_ip_ops`), the halfvec and binary-quantized index
shapes, hybrid search on all three metrics, keyword-only search, and the egress filter.

Because a skip would also report `PASSED` at the Bazel level, the passthrough was verified with a
control run of the same target with the variable unset:

| run | result |
|---|---|
| `GARAGE_TEST_DATABASE_URL` set | `16 passed in 1.04s` |
| variable unset | `16 skipped in 0.18s` |

So `.bazelrc`'s `test --test_env=GARAGE_TEST_DATABASE_URL` (line 23) does reach the sandboxed test,
and the bundled libpq resolves under Bazel — the suite connects and runs real SQL.

## 3. Through the venv — PASS

```
cd garage_python && GARAGE_TEST_DATABASE_URL=postgresql://localhost:5432/postgres \
  .venv/bin/python -m pytest -q tests/test_postgres.py

................                                                         [100%]
16 passed in 1.55s
```

Same 16 tests, same server, from outside Bazel.

**Setup note:** `garage_python/.venv` did not exist on this machine — neither in this worktree nor
in the main one — so `uv sync` was run first to create it (Python 3.13.13, resolved from
`uv.lock`). CLAUDE.md's "Swift app dev loop" section describes the venv as already present ("There
is also a real `.venv` under `garage_python/.venv`"); a fresh clone needs the `uv sync` step, which
may be worth stating explicitly next to the `GARAGE_TEST_DATABASE_URL` instructions. `.venv` is
gitignored (`.gitignore:2`), so creating it left the working tree clean.

## 4. No leftover databases — PASS

After both runs:

```
SELECT datname FROM pg_database WHERE datname LIKE 'garage_test%';   -- (0 rows)
SELECT datname FROM pg_database WHERE datname LIKE 'garage%';        -- (0 rows)
```

Not one `garage_test_*` database survives, and no `garage*` database of any kind remains on the
server — the throwaway database is created, migrated and dropped cleanly by each run, including
across the two separate invocations. The unrelated pre-existing databases on that server were
untouched.

## Environment left behind

`claude/adoring-ritchie-c084cj` unchanged at `db263ef`. No scratch databases remain. The app's
cluster was never started or connected to. `GARAGE_TEST_DATABASE_URL` was passed on the command
line only and is not written into any tracked file.

---

# Round 3 (4c067e4)

App Store signing on the M3, split with the M4 (the M4 covers the Developer ID universal app and
the full `aspect test //...`). Same machine: Apple M3 Max · macOS 27.0 (26A428) · Xcode 27.0
(27A266a). Checked out `4c067e4` ("Stage frameworks for codesign_test with real files and relative
links") detached; `7cdbdc5` and `8735dff` are its parents.

Identities on this Mac's keychain: Apple Development, Garage Local Signing, Developer ID Application
and **Apple Distribution: Richard Penwell (DWVXMLB45Y)**.

| Step | Result |
|---|---|
| 1. `aspect build //macapp:GarageStore.app` + codesign checks | **PASS** (two entitlement notes below) |
| 2. `aspect build //macapp:GarageStore.xcarchive` + checks | **PASS** (`dSYMs/` is empty) |
| 3. `codesign_test` targets | **FAIL** under the default sandboxed run; passes outside the sandbox |
| 4. Python tests under Bazel, then the venv | **PASS**: 26/26 targets, 597 venv tests (with one venv workaround) |

**No Keychain prompt appeared.** Both Apple Distribution builds signed without stopping, and no
signing step waited for a Keychain ACL. The only prompt of any kind was the Secretive git-signing
request in step 4, which is unrelated to the build.

Not run, per instructions: notarize, the installer, pkgbuild, any install target, `xcarchive_open`,
and any upload (altool, notarytool, Transporter). The app's cluster on 14824 was not started or
contacted; it had no listener the whole time.

## 1. `//macapp:GarageStore.app`: PASS

`aspect build //macapp:GarageStore.app` exited 0 in 7 m 51 s (175 actions). The output is
`bazel-out/darwin_arm64-fastbuild-macos-arm64-min14.0-ST-a379604bb3e5/bin/macapp/Sources/GarageApp/GarageApp.zip`,
a zip, and `bazel-bin` does not point at that configuration, so the path is config-specific. The
checks below ran on the unzipped `Garage.app`.

```
$ codesign --verify --deep --strict --verbose=2 Garage.app
...
Garage.app: valid on disk
Garage.app: satisfies its Designated Requirement
[exit=0]

$ codesign -dvv Garage.app
Identifier=me.rickmark.garage-rag
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=75394 flags=0x10000(runtime) hashes=2345+7 location=embedded
Authority=Apple Distribution: Richard Penwell (DWVXMLB45Y)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=DWVXMLB45Y
Runtime Version=27.0.0
Sealed Resources version=2 rules=13 files=25404
```

The authority chain matches what was expected, and hardened runtime is set (`flags=0x10000(runtime)`).

Entitlements (`codesign -d --entitlements - Garage.app`):

```
com.apple.security.app-sandbox                    true
com.apple.security.application-groups             [DWVXMLB45Y.group.me.rickmark.garage-rag]
com.apple.security.cs.disable-library-validation  true
com.apple.security.files.bookmarks.app-scope      true
com.apple.security.files.user-selected.read-only  true
com.apple.security.files.user-selected.read-write true
com.apple.security.network.client                 true
com.apple.security.network.server                 true
```

Nested code. Every item returns `valid on disk` / `satisfies its Designated Requirement`, exit 0,
Authority=Apple Distribution, TeamIdentifier=DWVXMLB45Y:

| Item | Identifier |
|---|---|
| `Frameworks/Python.framework` | `org.python.python` |
| `Frameworks/PythonXPCService.framework` | `me.rickmark.garage-rag.PythonXPCService` |
| `XPCServices/GarageEmbedXPCService.xpc` | `me.rickmark.garage-rag.embed-xpc` |
| `XPCServices/GarageIngestXPCService.xpc` | `me.rickmark.garage-rag.ingest-xpc` |
| `XPCServices/GarageMCPServerService.xpc` | `me.rickmark.garage-rag.mcp-server-xpc` |
| `XPCServices/GarageXPCService.xpc` | `me.rickmark.garage-rag.xpc` |
| `XPCServices/LlamaXPCService.xpc` | `me.rickmark.garage-rag.llama-xpc` |
| `XPCServices/ModelDownloadXPCService.xpc` | `me.rickmark.garage-rag.model-download-xpc` |

`Contents/embedded.provisionprofile` is **present**. Decoded with `security cms -D`: name
`GarageMacAppConnect`, team `DWVXMLB45Y`, expires 2027-09-01, and it is a distribution profile (no
`ProvisionedDevices`). Its entitlements:

```
com.apple.application-identifier        DWVXMLB45Y.me.rickmark.garage-rag
com.apple.developer.team-identifier     DWVXMLB45Y
com.apple.security.application-groups   [group.me.rickmark.garage-rag, DWVXMLB45Y.*]
keychain-access-groups                  [DWVXMLB45Y.*]
com.apple.developer.sustained-execution true
```

The app's group `DWVXMLB45Y.group.me.rickmark.garage-rag` is covered by the `DWVXMLB45Y.*` wildcard.

### Entitlement notes: not failures here, but likely to matter at upload

These came from reading the signatures. Nothing was uploaded, so App Store Connect's verdict on them
is **not verified**.

1. **The signed app carries no `com.apple.application-identifier` or
   `com.apple.developer.team-identifier` entitlement.** The profile grants both, and Xcode-archived
   Mac App Store apps normally embed them. App Store validation typically rejects a sandboxed app
   whose signature lacks the application identifier, so this is the first thing to check if an
   upload is refused.
2. **Every XPC service has `com.apple.security.inherit = true` alongside its own entitlements.**
   Those entitlements are the app-sandbox, application-groups, network, file-access and
   disable-library-validation set. Apple documents `inherit` as valid only with `app-sandbox` and
   nothing else, and it is meant for helper executables launched as child processes, not for XPC
   services, which get their own sandbox from their own entitlements. Each service here already
   has a full sandbox set, so dropping `inherit` looks like the fix. As it is, the combination risks
   the service failing to launch sandboxed, or being rejected at validation.

## 2. `//macapp:GarageStore.xcarchive`: PASS

`aspect build //macapp:GarageStore.xcarchive` exited 0 in 19.9 s, reusing the step 1 outputs. The
archive is at `bazel-out/darwin_arm64-fastbuild-ST-37fe811ccc69/bin/macapp/_GarageStore_xcarchive_raw/Garage.xcarchive`.

```
$ codesign --verify --deep --strict --verbose=2 Products/Applications/Garage.app
Products/Applications/Garage.app: valid on disk
Products/Applications/Garage.app: satisfies its Designated Requirement
[exit=0]
Authority=Apple Distribution: Richard Penwell (DWVXMLB45Y)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA

$ codesign --verify --deep --strict --verbose=2 Products/Applications/Garage.app/Contents/Frameworks/Python.framework
...Python.framework: valid on disk
...Python.framework: satisfies its Designated Requirement
[exit=0]

$ plutil -p Info.plist
{
  "ApplicationProperties" => {
    "ApplicationPath" => "Applications/Garage.app"
    "CFBundleIdentifier" => "me.rickmark.garage-rag"
    "CFBundleShortVersionString" => "0.9"
    "CFBundleVersion" => "213"
    "SigningIdentity" => "Apple Distribution: Richard Penwell (DWVXMLB45Y)"
  }
  "ArchiveVersion" => 2
  "CreationDate" => 2026-09-23 13:22:29 +0000
  "Name" => "Garage"
  "SchemeName" => "Garage"
}
```

Note: the archive's `dSYMs/` directory is **empty**, even though step 1 produced
`Garage.app.dSYM` (`--apple_generate_dsym` is on in `.bazelrc`). An upload would then carry no
symbols for crash reports. Xcode's archives also add `Team` and `Architectures` under
`ApplicationProperties`; this one lacks both. Organizer and upload tooling may or may not require
them. This was not tested.

## 3. `codesign_test` targets: FAIL (sandbox-only)

`aspect query` does not exist in this Aspect CLI (v2026.28.4): it reports "unrecognized subcommand
'query'". `bazel query` was used instead:

```
$ bazel query 'kind(codesign_test, //...)'
//ext/python:python_framework_codesign_test
[exit=0]
```

That is the only target. `aspect test` also rejects `--test_output=errors` on the command line
("unexpected argument"), and `-- --test_output=errors` is taken as a target pattern. The working
form is `--bazel-flag=--test_output=errors`.

```
$ aspect test //ext/python:python_framework_codesign_test --bazel-flag=--test_output=errors
Expected signing identity: Garage Local Signing
Store distribution:        NO
Hardened runtime required: NO
Verifying bundle: Python.framework
.../stage/Python.framework: bundle format is ambiguous (could be app or framework)
[FAIL] Bundle verification failed: Python.framework
.../stage/Python.framework/Python: bundle format is ambiguous (could be app or framework)
[FAIL] Python.framework/Python: codesign verification failed
[PASS] Python.framework/Versions/3.13/Python
[PASS] Python.framework/Versions/Current/Python
Checked 3 Mach-O binaries: 2 passed, 1 failed
Bundles: 1 failed verification
//ext/python:python_framework_codesign_test   FAILED in 15.3s
[exit=3]
```

**Progress from before 4c067e4:** "Too many levels of symbolic links" and the "-1 passed" count are
**gone**. The test now reaches codesign and counts correctly. It still fails, though, and the
failure is in the test's staging, not the framework.

**Cause:** under darwin-sandbox, the framework's internal links do not reach the test as relative
links. The top-level `Python` and `Versions/Current` arrive as **absolute** links into the execroot,
because Bazel resolves symlinks inside a tree artifact when it stages it into the sandbox. 4c067e4's
new pass replaces every absolute link with a `cp -RL` copy. That turns `Python` into a regular file
and `Versions/Current` into a real directory, so the staged framework is flattened, and codesign
correctly calls it ambiguous. The log gives it away: `Versions/Current/Python` is checked as a
regular file, which cannot happen if `Current` were a link.

Evidence that the framework itself is fine:

- The real output tree `bazel-bin/ext/python/Python.framework` has the right relative links
  (`Python -> Versions/Current/Python`, `Resources -> …`, `Headers -> …`, `Versions/Current ->
  3.13`). The test's own `tar` staging, run by hand from that tree, keeps all four as relative links.
- The same test **passes** when run outside the sandbox:

  ```
  $ aspect test //ext/python:python_framework_codesign_test --bazel-flag=--test_output=errors \
      --bazel-flag=--strategy=TestRunner=local --bazel-flag=--nocache_test_results
  [PASS] Bundle valid: Python.framework
  [PASS] Python.framework/Versions/3.13/Python
  Checked 1 Mach-O binaries: 1 passed, 0 failed
  //ext/python:python_framework_codesign_test   PASSED in 2.7s
  ```
- The Apple Distribution-signed copy inside `GarageStore.app` and inside the archive verifies with
  `--deep --strict` (steps 1–2).

Possible fixes: have the staging rebuild the canonical framework links (`Versions/Current -> <ver>`
and top-level `X -> Versions/Current/X`) after resolving the absolute ones, instead of copying them
through. Or tag the test `no-sandbox` / `local`.

Also noted: the test ran under the default `local_signed` config (Garage Local Signing, not store).
`--config=store` cannot run it at all, because no execution platform satisfies
`//bazel:universal_store`:

```
ERROR: ... While resolving toolchains for target //ext/python:python_framework_codesign_test:
No matching toolchains found for types: @@bazel_tools//tools/test:default_test_toolchain_type
```

So the `is_store` / Apple Distribution assertions in `codesign_test` are currently unreachable from
`aspect test`.

## 4. Python tests: PASS

Server: Homebrew PostgreSQL 18.4, pgvector 0.8.6, `localhost:5432`, same as the db263ef run.

```
$ GARAGE_TEST_DATABASE_URL=postgresql://localhost:5432/postgres \
    aspect test //garage_python/tests:suite --bazel-flag=--test_output=errors
Executed 26 out of 26 tests: 26 tests pass.
[exit=0]
```

| Target | Result | Test log |
|---|---|---|
| `test_ingest_gateway` (7cdbdc5) | **PASSED** | 12 passed |
| `test_scanner` (7cdbdc5) | **PASSED** | 16 passed |
| `test_migrate` (8735dff) | **PASSED** | 11 passed |
| `test_postgres` | **PASSED** | 16 passed, not skipped |

The other 22 targets also passed. No `garage*` databases were left on the server afterwards.

### venv

`garage_python/.venv` was missing again, so `uv sync` created it (exit 0).

The first `.venv/bin/python -m pytest -q` **hung** in `test_scanner.py::test_scan_git_repository`.
The test's `git commit` picks up the user's global `commit.gpgsign = true` with `gpg.format = ssh`,
so it ran `ssh-keygen -Y sign` against a Secretive (Secure Enclave) key. That waited on an approval
prompt for over 10 minutes before the run was killed; nothing was approved. It did not happen under
Bazel, where the sandbox does not see the global git config. The test should isolate itself:
`-c commit.gpgsign=false` on the commit, or `GIT_CONFIG_GLOBAL=/dev/null` in the subprocess env.

With the global git config masked:

```
$ GIT_CONFIG_GLOBAL=/dev/null GARAGE_TEST_DATABASE_URL=postgresql://localhost:5432/postgres \
    .venv/bin/python -m pytest -q
597 passed in 15.62s
[exit=0]
```

## Environment left behind

`claude/adoring-ritchie-c084cj` unchanged; nothing was pushed to it. The main checkout was returned
to `second_machine_build`, which was not modified. `garage_python/.venv` now exists (gitignored). No
`garage*` databases remain on the Homebrew server. The app's 14824 cluster was never touched.
Unzipped copies of the app sit in the session scratchpad only.

# Check of 898c0e6

Second-machine validation of `898c0e6` ("Close SwiftUI sheets through their state before
quitting"), which was the head of PR #15 when this was requested. **The branch has since moved on
by one commit**, to `97e3dd2` ("Bound stalled placeholder reads; decode captured output across pipe
reads"), and that commit was not checked here. Same machine: Apple M3 Max (`Mac15,9`) · macOS 27.0
(26A428) · Xcode 27.0 (27A266a) · Bazel 9.2.0 through the aspect launcher 2026.38.20. The check ran
in a fresh detached worktree (`~/Developer/garage-pr15`), with a cold output base.

2026-09-23 19:11–19:40 UTC. No notarize, installer, pkgbuild, install target, `xcarchive_open` or
upload, and nothing was copied into `/Applications`. The tests used Homebrew's server
(`GARAGE_TEST_DATABASE_URL=postgresql://localhost:5432/postgres`, PostgreSQL 18.4, pgvector 0.8.6),
not the app's cluster on 14824. No TCC prompt was accepted, and Reset Database was not run.

| Step | Result |
|---|---|
| 1. `aspect test //... --bazel-flag=--test_output=errors` | **PASS**: 31/31 targets, 643.8 s wall (cold) |
| 2. venv `pytest -q` | **PASS**: 597 passed, 0 skipped, 44.9 s |
| 3. Developer ID app: build, launch, services | **PASS** (build 225, all three listeners up in 10 s) |
| 3. Migration, with a backup first | **Not observable**: this Mac had already migrated, see below |
| 3. Database page, masked password, ⌘Q with the splash up | **Not run**: no accessibility access (see below) |

## 1. `aspect test //...`: PASS, 31/31

Started 19:11:44Z, finished 19:22:28Z: `real 643.83` s, which includes building everything from
a cold output base. Exit 0.

```
//bazel:preset.update_test                                               PASSED in 0.3s
//ext/python:python_framework_codesign_test                              PASSED in 15.4s
//garage_python/tests:test_attribution                                   PASSED in 1.7s
//garage_python/tests:test_chunking                                      PASSED in 2.7s
//garage_python/tests:test_cli_serve                                     PASSED in 3.6s
//garage_python/tests:test_config                                        PASSED in 1.4s
//garage_python/tests:test_dedicated_rpcs                                PASSED in 1.4s
//garage_python/tests:test_egress_block                                  PASSED in 6.3s
//garage_python/tests:test_embed_egress                                  PASSED in 1.7s
//garage_python/tests:test_embed_xpc                                     PASSED in 1.7s
//garage_python/tests:test_facts                                         PASSED in 10.4s
//garage_python/tests:test_generation                                    PASSED in 1.3s
//garage_python/tests:test_grpc_documents                                PASSED in 1.5s
//garage_python/tests:test_grpc_operations                               PASSED in 1.6s
//garage_python/tests:test_grpc_serialization                            PASSED in 2.6s
//garage_python/tests:test_grpc_server                                   PASSED in 3.4s
//garage_python/tests:test_ingest_gateway                                PASSED in 2.0s
//garage_python/tests:test_ingest_xpc                                    PASSED in 1.6s
//garage_python/tests:test_llama_embedder                                PASSED in 3.3s
//garage_python/tests:test_llama_xpc                                     PASSED in 11.7s
//garage_python/tests:test_lmstudio                                      PASSED in 2.2s
//garage_python/tests:test_mcp_install                                   PASSED in 5.4s
//garage_python/tests:test_mcp_server                                    PASSED in 3.3s
//garage_python/tests:test_migrate                                       PASSED in 1.6s
//garage_python/tests:test_model_catalog                                 PASSED in 3.2s
//garage_python/tests:test_postgres                                      PASSED in 4.8s
//garage_python/tests:test_registry_dims                                 PASSED in 3.2s
//garage_python/tests:test_scanner                                       PASSED in 2.4s
//macapp/Tests/GarageAppUITests:GarageAppUITests                         PASSED in 4.3s
//macapp/Tests/GarageAppUnitTests:GarageAppUnitTests                     PASSED in 58.7s
//macapp/Tests/LlamaClientTests:LlamaClientTests                         PASSED in 3.8s

Executed 31 out of 31 tests: 31 tests pass.
```

`GarageAppUnitTests` ran **241 tests, 0 failures**. `test_postgres` ran against the Homebrew
server, not skipped. `python_framework_codesign_test` passed under the default sandboxed run.

## 2. venv pytest: PASS, 597

`uv sync` in `garage_python`, then `GIT_CONFIG_GLOBAL=/dev/null pytest -q` with the same
`GARAGE_TEST_DATABASE_URL`: **597 passed in 44.93 s**, none skipped, exit 0. No workaround was
needed this time.

## 3. Developer ID app

**Build.** `aspect build //macapp/package:GarageApp` exited 0 (4,478 actions, about 10 min cold).
Extracted with `ditto -x -k` to `~/GarageTest/Garage.app`: **version 0.9, build 225**.
- `codesign --verify --deep --strict` passes.
- Authority `Developer ID Application: Richard Penwell (DWVXMLB45Y)`.
- `spctl -a` says `accepted, source=Developer ID`.

No other Garage.app was running, and nothing listened on 14824, 8787 or 50051 beforehand.

**Migration: already done on this Mac, so it could not be watched.**
- `~/Library/Application Support/GarageApp` was already a link into the group container, dated
  09:57 local. That was from an earlier launch today of `claude/adoring-ritchie-c084cj` code, on
  the working checkout.
- The backup was still taken before launch: `ditto` of the group-container folder, which is what
  the link points at, to **`~/GarageBackup-2026-09-23/GarageApp`** (3.0 GB: `models` 2.7 GB,
  `pgdata` 324 MB, `logs` empty).
- After launch the link was unchanged (same target, same 09:57 timestamp), so there was no second
  migration and no data move.
- Before launch, `pg_controldata` reported **`in production`** with no postmaster running: the
  cluster had not been shut down cleanly after its last use. The likely cause is a debug instance
  killed earlier today. Postgres started on it anyway (see below).

**Launch and services: PASS.** `open ~/GarageTest/Garage.app` at 19:34:28Z. By 19:34:38Z, 10 s
later, all three were listening:

```
postgres  46610  127.0.0.1:14824, [::1]:14824
GarageMCP 46606  127.0.0.1:8787
GarageXPC 46607  127.0.0.1:50051
```

The postmaster's parent is the app (46583), and it runs from the bundle:
`~/GarageTest/Garage.app/Contents/Resources/postgres/bin/postgres -D ~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/pgdata -p 14824 -c listen_addresses=localhost …`.

**Not run: Database page paths, `••••••` masking, ⌘Q with the splash up, `pg_controldata` after
quit.**
- The session's host process has no accessibility access here:
  `osascript is not allowed assistive access (-1728)`. So I could neither read the window nor send
  ⌘Q.
- Granting it means accepting a TCC prompt, which these instructions rule out. Screen recording is
  also missing, and granting it would restart the host app.
- These four checks need a person at the Mac, or an accessibility grant decided by the user.
- **The app was left running** (pid 46583) for that. Quit it with ⌘Q, then run
  `pg_controldata "…/pgdata" | grep state`, which should say `shut down`.

# Check of 97e3dd2

The PR head moved on to `97e3dd2` while the 898c0e6 check above ran. Per the update, I re-ran just
the new and app tests on it (detached, same worktree, with Homebrew's server for tests):
`aspect test //garage_python/tests:test_materialize //macapp/Tests/... --bazel-flag=--test_output=errors`.

| Target | Result |
|---|---|
| `//garage_python/tests:test_materialize` | **PASSED** in 1.9 s, 4 tests |
| `//macapp/Tests/GarageAppUnitTests:GarageAppUnitTests` | **PASSED** in 30.5 s: **245 tests, 0 failures**, including the new `UTF8StreamDecoderTests` |
| `//macapp/Tests/GarageAppUITests:GarageAppUITests` | **PASSED** in 2.9 s |
| `//macapp/Tests/LlamaClientTests:LlamaClientTests` | **PASSED** in 3.4 s |

4/4 targets, 50 s wall (warm). `97e3dd2` is also what was merged into `claude/reset-xcuitest`.

# OpenSSL paths in the bundle

Read-only look at the Developer ID app built in the 898c0e6 check (`~/GarageTest/Garage.app`,
build 225). No code was changed.

## Answer

The `/opt/homebrew/etc/openssl@3` path comes from **`cryptography` 43.0.3's prebuilt wheel**. Its
`_rust.abi3.so` statically links pyca's own **OpenSSL 3.3.2** (built on pyca's macOS CI, so its
compiled-in `OPENSSLDIR` is Homebrew's). It is not from `//ext/openssl`, and it does not load any
Homebrew library: its only load commands are `/usr/lib/libiconv.2.dylib` and
`/usr/lib/libSystem.B.dylib`. It does **read** `openssl.cnf` from that directory when its OpenSSL
initializes. That was the M4's harmless sandbox denial, and on a Developer ID build it reads whatever
is there. **Nothing in the bundle loads a Homebrew dylib at runtime.**

Separately, **our own `_ssl` has no usable default CA paths.** `//ext/openssl`'s `OPENSSLDIR` is the
Bazel build sandbox (`…/sandbox/darwin-sandbox/5840/…/ext/openssl/openssl.build_tmpdir/openssl/ssl`),
so `ssl.create_default_context()` in the app loads **0 CA certificates** on every Mac.

## 1. Every file with `/opt/homebrew`, `/usr/local/ssl` or `OPENSSLDIR`

`grep -rl --binary-files=binary` over the whole bundle:
- `/opt/homebrew`: **11 files**, all Mach-O.
- `/usr/local/ssl`: **0 files**.
- `OPENSSLDIR`: the `_rust.abi3.so` and `_ssl` strings below.

| File | `/opt/homebrew` string | What it is |
|---|---|---|
| `Resources/site-python/site-packages/cryptography/hazmat/bindings/_rust.abi3.so` | `OPENSSLDIR: "/opt/homebrew/etc/openssl@3"`, `…/openssl@3/cert.pem`, `…/openssl@3/certs` | PyPI wheel `cryptography-43.0.3`, `Generator: maturin (1.7.0)`, tag `cp39-abi3-macosx_10_9_universal2`, installed by `aspect_rules_py`. Static `OpenSSL 3.3.2 3 Sep 2024`. |
| `MacOS/garage`, `MacOS/garage-mcp`, `Frameworks/PythonXPCService.framework/PythonXPCService`, and the six `XPCServices/*.xpc` executables (9 files) | `/opt/homebrew/Frameworks/` | PythonKit's `librarySearchPaths = ["", "/opt/homebrew/Frameworks/", "/usr/local/Frameworks/"]` (`PythonKit/PythonLibrary.swift:104`), compiled in with `//ext/pythonkit`. Not a load command or rpath (see 2). |
| `MacOS/GarageApp` | `/opt/homebrew/bin/garage-mcp` | Our `macapp/Sources/GarageApp/Services/Paths.swift:202`: a developer fallback in the `garage-mcp` lookup, used only when the bundled `Contents/MacOS/garage-mcp` is missing. |

## 2. Load commands and rpaths

All 249 Mach-O files in the bundle were checked with `otool -L` and their `LC_RPATH`s.
**No load command and no rpath points into `/opt/homebrew` or `/usr/local`.**

`_rust.abi3.so` (cryptography):
```
@rpath/cryptography.hazmat.bindings._rust.abi3.so (compatibility version 0.0.0, current version 0.0.0)
/usr/lib/libiconv.2.dylib (compatibility version 7.0.0, current version 7.0.0)
/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1336.61.1)
```
No `LC_RPATH`.

**PythonKit never reaches its Homebrew search path.**
- `PythonLibrary.loadPythonLibrary()` first checks whether Python is already loaded in the process
  (`isPythonLibraryLoaded()`, then `defaultLibraryHandle`). Only if it isn't does it try
  `PYTHON_LIBRARY`, then its search paths.
- Every Python-using binary links `@rpath/Python.framework/Versions/3.13/Python` at load time:
  `garage`, `garage-mcp`, `PythonXPCService.framework` and all six XPC executables show it in
  `otool -L`. `GarageApp` gets it through `PythonXPCService.framework`.
- So the search is dead code in this bundle. It would still run if a binary using PythonKit ever
  stopped linking Python.

Load commands or rpaths outside the bundle and system that are **not** Homebrew (all harmless at
runtime, listed for completeness):
- `site-python/config-3.13-darwin/libpython3.13.a`: a static archive that is never loaded. Its
  recorded dependency is the Bazel sandbox's `Python.framework`. It is dead weight in the bundle.
- `site-packages/google/_upb/_message.abi3.so` (protobuf wheel): install name
  `bazel-out/k8-opt-ST-d581c5370a66/bin/python/lib_message_binary.so`, from Google's Linux CI.
- `site-packages/PIL/.dylibs/libjpeg.62.4.0.dylib` (Pillow wheel): rpath
  `/Users/runner/work/Pillow/Pillow/build/deps/darwin/lib`.
- 21 Postgres and libpq dylibs: rpaths into this Mac's Bazel sandbox
  (`…/postgres.ext_build_deps/{libicu,libreadline,libzlib}_shared/lib`), next to the bundle-relative
  ones that actually resolve.
- 10 Swift binaries: the toolchain rpaths
  `/private/var/select/developer_dir/…/swift-6.2/macosx` and
  `/var/db/xcode_select_link/…/swift-6.2/macosx`, after `/usr/lib/swift`.

## 3. `_ssl` and `_hashlib`

In `Resources/site-python/lib-dynload`:
- Both `_ssl.cpython-313-darwin.so` and `_hashlib.cpython-313-darwin.so` link only `/usr/lib` and
  `/System` libraries: `libc++`, Foundation, `libobjc`, `libSystem`.
- Both carry the OpenSSL symbols themselves, so they are **statically linked against
  `//ext/openssl`**: `OpenSSL 3.4.7 25 Aug 2026`.
- `_ssl` has `OPENSSLDIR: "/Users/rickmark/Library/Caches/bazel/_bazel_rickmark/006d35fe81451c822614e361922fd371/sandbox/darwin-sandbox/5840/execroot/_main/bazel-out/darwin_arm64-fastbuild-macos-arm64-min14.0-ST-3ad2ede33e28/bin/ext/openssl/openssl.build_tmpdir/openssl/ssl"`.

**The bundle has no `python` executable** (`bin/` is stripped from `Python.framework`), and the Bazel
`python3.13` is a launcher that re-executes `Python.app`, which isn't shipped. So I compiled a
two-line `Py_BytesMain` host, in a scratch directory, against the bundle's own `Python.framework`.
Its `sys.prefix` was the bundle's `site-python`:
```
_ssl     : <site-python>/lib-dynload/_ssl.cpython-313-darwin.so
version  : OpenSSL 3.4.7 25 Aug 2026
paths    : DefaultVerifyPaths(cafile=None, capath=None, openssl_cafile_env='SSL_CERT_FILE',
           openssl_cafile='…/sandbox/darwin-sandbox/5840/…/ext/openssl/openssl.build_tmpdir/openssl/ssl/cert.pem',
           openssl_capath_env='SSL_CERT_DIR',
           openssl_capath='…/sandbox/darwin-sandbox/5840/…/ext/openssl/openssl.build_tmpdir/openssl/ssl/certs')
exists   : cafile False | openssl_cafile False | openssl_capath False
default context CA certs: 0
certifi context CA certs: 121
```

- Neither the Python code nor the Swift side sets `SSL_CERT_FILE`, `SSL_CERT_DIR` or `OPENSSL_CONF`,
  or uses `certifi` or `truststore` explicitly. Both packages are bundled: `certifi` 2026.7.22 and
  `truststore` 0.10.4.
- `httpx`, which the `anthropic` client uses, picks up `certifi` itself, so it is unaffected.
- Anything that uses `ssl.create_default_context()` or `urllib` with the defaults fails
  certificate verification.

## 4. Would anything load Homebrew at runtime?

**No dylib, no framework and no plugin comes from Homebrew.** Nothing in the bundle has a load
command or rpath there, and PythonKit's search path is never reached (see 2). A Mac without
Homebrew runs the same code.

Homebrew is still **read** at runtime in two ways, which the "never Homebrew" rule rules out:
- **`cryptography`'s OpenSSL loads `/opt/homebrew/etc/openssl@3/openssl.cnf`** when it initializes.
  That happens whenever something imports it: `garage-rag` depends on it directly, and so do
  `pdfminer-six` (the PDF extractor) and `google-auth`.
  - With no such file, that is a no-op.
  - With one, the app runs under whatever configuration someone left in their Homebrew folder.
    `openssl.cnf` can change defaults and name provider modules. Library validation should stop an
    unsigned provider loading into the hardened-runtime app, but the rest still applies.
- **The two developer fallbacks** (PythonKit's search path, `Paths.swift`'s
  `/opt/homebrew/bin/garage-mcp`) are only reached when the bundle is broken. They are still paths
  into Homebrew in shipped code.

Possible fixes, not made here:
1. Export `OPENSSL_CONF` pointing at an empty `openssl.cnf` shipped in the bundle, from
   `GaragePythonRuntime`, the way it exports `GARAGE_LIBPQ_PATH`. That covers `cryptography` and
   `_ssl`.
2. Export `SSL_CERT_FILE` as `certifi.where()`, or call `truststore.inject_into_ssl()` at Python
   start-up, so default contexts verify.
3. Give `//ext/openssl` a fixed `--openssldir`. The sandbox path is useless and names the build
   user.
4. Drop the PythonKit and `Paths.swift` Homebrew candidates. PythonKit could be patched, or given
   `PYTHON_LIBRARY` explicitly.
5. Drop `site-python/config-3.13-darwin` from the bundle.

# OpenAI-compatible API probe

Can one small OpenAI-compatible (`/v1`) client replace both the `openai` SDK and the `ollama`
package, and can LM Studio drive langextract?

2026-09-23 20:25–20:40 UTC, on the M3, at `97e3dd2`, in the venv (`garage_python/.venv`: langextract
1.7.0, `ollama` 0.6.2, `openai` 3.3.1). Scratch scripts and their output are in
`~/GarageTest/api-probe/`. No repo code changed, nothing was installed, updated or downloaded, and
Garage's database, port 14824 and the app were not touched.

**What was there:**
- **LM Studio 0.4.25+1** (already running, port 1234). It **needed no API token**: `/v1/models`,
  `/v1/embeddings` and `/v1/chat/completions` all answered without one, so no token was read.
  Nine models, none loaded at the start. Used:
  - `text-embedding-nomic-embed-text-v1.5`: `nomic-bert`, Q4_K_M GGUF, 768 dims.
  - `google/gemma-3-4b`: MLX 4-bit.
  - Both were JIT-loaded by the requests and unloaded afterwards (`lms unload --all`).
- **Ollama 0.34.3** (already running, port 11434). **One model only: `llama4:latest`**, 108.6B,
  Q4_K_M, digest `bf31604e25c2`, capabilities `completion, vision, tools`.
  - **No embedding model is installed** (neither `nomic-embed-text` nor `bge-m3`), and none was
    pulled.
- **Garage's `llama_xpc`** (port 8790, the app from the 898c0e6 check): `no_model_loaded`.
  - Loading a model is an NSXPC call from the app (`LlamaXPCProtocol.loadModel`), not an HTTP route,
    so its vectors were **not measured**.
  - Garage's own models folder has `nomic-embed-text-v1.5.Q8_0.gguf`. That is **not the same GGUF**
    as LM Studio's Q4_K_M.

## 1. LM Studio on Ollama's routes

| Request | Result |
|---|---|
| `GET /api/tags` | **HTTP 200**, `{"error":"Unexpected endpoint or method. (GET /api/tags)"}` |
| `POST /api/embed` | **HTTP 200**, `{"error":"Unexpected endpoint or method. (POST /api/embed)"}` |
| `POST /api/chat` | **HTTP 200**, `{"error":"Unexpected endpoint or method. (POST /api/chat)"}` |

As expected, LM Studio does not speak Ollama's API. **But it answers with 200 and an error body, not
404.** A client has to check the body. Garage's `LlamaXPCClient` raises only on non-2xx, so a wrong
route there would surface as "reply has no 'data' list" or a `KeyError`, not as a clean HTTP error.

## 2. Ollama: `/api/embed` vs `/v1/embeddings`

**Not measurable here**: the only model, `llama4:latest`, has no embedding capability. Both routes
refuse it in the same way:
- `/api/embed` → **HTTP 501**
  `{"error":"This server does not support embeddings. Start it with --embeddings"}`
- `/v1/embeddings` → **HTTP 501**, the same message in OpenAI's error shape (`{"error":{"message":…,"type":"api_error"}}`)

So max-abs difference, cosine per pair, L2 norms, `dimensions` and batching are unmeasured for
Ollama. Measuring them needs `nomic-embed-text` or `bge-m3` pulled into Ollama, which is a download.

## 3. LM Studio `/v1/embeddings` (nomic-embed-text v1.5, Q4_K_M)

- **Shape:** `{"object","data","model","usage"}`. Each `data[i]` is `{"object":"embedding","index","embedding"}`,
  with indexes 0–4 in input order. This is exactly what `embed/lmstudio.py` reads
  (`response.data[i].embedding` through the `openai` SDK), and what `LlamaXPCClient.embed_texts`
  reads (`data[*].index` / `embedding`).
  - `usage` is `{"prompt_tokens":0,"total_tokens":0}`: LM Studio does not count tokens.
- **Same vectors through either client.** The same 5 texts went through Garage's `LlamaXPCClient`
  and through the `openai` SDK: max abs difference **0.0**, cosine **1.000000000** for all 5. The
  first request (JIT load) took 20.4 s; after that, 49 ms (`LlamaXPCClient`) and 543 ms (SDK).
- **Normalized:** L2 norm **1.000000** for every vector.
- **Batched = single:** text 2 alone vs in the batch, max abs difference 0.0.
- **`dimensions` is silently ignored:** `dimensions: 256` returned HTTP 200 with **768** dimensions.
  This doesn't matter for Garage, which truncates on its side (`registry.truncate_vector` in
  `embed/ollama.py` and `search/hybrid.py`). But LM Studio must never be relied on to truncate.

## 4. Completions for langextract

### (a) `response_format` on `/v1/chat/completions`

| Server, model | `json_object` | `json_schema` (strict, `{"facts":[string]}`) |
|---|---|---|
| LM Studio, `google/gemma-3-4b` | **HTTP 400** `'response_format.type' must be 'json_schema' or 'text'` | HTTP 200, 2.7 s, valid JSON matching the schema |
| Ollama `/v1`, `llama4:latest` | HTTP 200, 4.2 s, valid JSON | HTTP 200, 2.5 s, valid JSON matching the schema |

A shared client that asks for JSON has to use `json_schema`, not `json_object`, or LM Studio refuses
the request.

### (b) Real langextract extraction

`enrich/facts.py`'s `PROMPT` and `EXAMPLES`, three short paragraphs (405 characters),
`use_schema_constraints=False`, as `facts.extract_facts` does it:
- the first two runs through the repo's `LlamaXPCLanguageModel` with a `LlamaXPCClient` pointed at
  each server's base URL (no subclass needed: loopback, no token);
- the third through `facts.ollama_model_config(...)`, today's `ollama` provider.

| Backend | Extractions | Grounded (`char_interval` set) | Time |
|---|---|---|---|
| LM Studio `/v1`, `google/gemma-3-4b`, via `LlamaXPCLanguageModel` | 7 | **7/7** | **2.8 s** |
| Ollama `/v1`, `llama4:latest`, via `LlamaXPCLanguageModel` | 5 | **5/5** | 9.3 s |
| Ollama `/api/generate`, `llama4:latest`, via langextract's Ollama provider (today's path) | 5 | **5/5** | 28.1 s |

- The two `llama4` runs produced the **same 5 spans**, from `[0:86]` "Garage stores its index…"
  to `[310:405]` "Messages and Mail are classified as communications, and Garage never sends them to
  a cloud API."
- gemma-3-4b split two of those sentences into smaller facts, so it has 7.
- **The `/v1` route was 3× faster than `/api/generate` for the same model and output.** The
  `/api/generate` run came last, so the model was already loaded.
- `LlamaXPCLanguageModel` sends no `response_format`; it relies on the prompt. That was enough for
  all three backends.

## 5. Ollama-only features

- **Model lists match:** `/v1/models` lists the same models as `/api/tags` (here just
  `llama4:latest`). It lacks `/api/tags`' family, size, quantization and digest details.
- **Garage's `ollama` package use** (`garage_python/src`) is three calls, each with a `/v1`
  equivalent:
  - `embed/ollama.py:71`: `client.embed(model, input)` → `POST /v1/embeddings`.
  - `enrich/generation.py:145`: `client.show(model)`, used only as "does this model exist" →
    `GET /v1/models` membership, which is how the `llama_xpc` branch of the same function already
    works (`list_models`).
  - `enrich/generation.py:215`: `client.chat(model, messages, options={num_predict, temperature})` →
    `POST /v1/chat/completions` with `max_tokens` and `temperature`.
- **Not used anywhere:** `list`, `pull`, `ps`, `keep_alive` or `truncate`.
  - `pull` appears only in user-facing hints (`"pull it with 'ollama pull …'"`, and a comment in
    `facts.py`).
  - `truncate` hits are Garage's own `truncate_vector`.
- **Outside the package:** `facts.py`'s default `ollama` provider uses langextract's
  `OllamaLanguageModel` on `/api/generate`. Section 4(b) shows `LlamaXPCLanguageModel` on Ollama's
  `/v1` does the same job, faster.

## 6. Addendum: LM Studio's native REST v1 (model management)

Same LM Studio 0.4.25+1, 20:40–20:50 UTC. Token auth is **off** on this install (see 6.4). Nothing
was downloaded. The two models loaded here were already on disk, and both were unloaded again: the
final `GET /api/v1/models` shows no loaded instances.

Note: `~/GarageTest/` (the probe scripts, their `*.out` files, and the 898c0e6 test app) was deleted
by someone else during this addendum. The last check (6.2's `context_length` re-run) was run from
this session's scratch directory instead. The results above were recorded before that.

**6.1 `GET /api/v1/models`: HTTP 200**, `{"models": [...]}`, one item per downloaded model:
```
{"type","publisher","key","display_name","architecture","quantization":{"name","bits_per_weight"},
 "size_bytes","params_string","loaded_instances":[{"id","config":{...}}],"max_context_length",
 "format","capabilities":{"vision","trained_for_tool_use","reasoning"},"description","variants",
 "selected_variant"}
```
- It gives what `/v1/models` doesn't: the **type** (`"llm"` or `"embedding"`), **what is loaded**
  (`loaded_instances`, each with its `id` and live `config`, plus `remaining_ttl_seconds` for a JIT
  load), and **`max_context_length`**.
- Example: `{"key":"text-embedding-nomic-embed-text-v1.5","type":"embedding","max_context_length":2048,"format":"gguf","quantization":{"name":"Q4_K_M","bits_per_weight":4}}`.

**6.2 `POST /api/v1/models/load` with `echo_load_config: true`: HTTP 200.** The shape matches the
owner's description:

| Model | Reply | Time |
|---|---|---|
| `text-embedding-nomic-embed-text-v1.5` | `{"type":"embedding","instance_id":"text-embedding-nomic-embed-text-v1.5","load_time_seconds":0.231,"status":"loaded","load_config":{"context_length":2048}}` | 0.2 s |
| `google/gemma-3-4b` (MLX), `context_length: 8192` | `{"type":"llm","instance_id":"google/gemma-3-4b","load_time_seconds":7.248,"status":"loaded","load_config":{"context_length":131072,"parallel":4,"reasoning_budget_message":""}}` | 7.3 s |
| `google/gemma-3-4b`, again with `context_length: 16384` | same, `load_config.context_length` **131072** (also in `loaded_instances[].config` while loaded) | 5.7 s |

- **`context_length` was not applied to this MLX model.** It loaded at its 131072 maximum both
  times, with no error.
- Whether GGUF LLMs honour it is untested: the only GGUF LLMs here are the 17B–70B ones.
- The GGUF embedding model loaded at its own 2048 maximum.
- A client should read `load_config` back rather than assume the request was honoured.

**6.3 `POST /api/v1/models/unload` with `{"instance_id": …}`: HTTP 200, `{"instance_id": "<id>"}`**,
exactly the documented shape. 0.0 s for the embedding model and 0.6 s for gemma. An unknown instance
gets a proper **HTTP 404** `{"error":{"type":"model_not_found","message":"Model with instance identifier 'no-such-instance' is not loaded."}}`,
unlike the OpenAI-compatible side's HTTP 200 for unknown routes (section 1). The `instance_id`
returned by load equals the model key here.

**6.4 Auth: not testable with auth on without changing LM Studio's settings, so not done.** With
token auth **off** (this install), `GET /api/v1/models` returned HTTP 200 with no token, **and HTTP
200 with a wrong bearer token**. The server doesn't validate a token it isn't configured to require.
So sending the token is harmless when auth is off. What an unauthenticated call returns with auth on
still needs checking, by someone who switches auth on.

**6.5 JIT on the OpenAI-compatible routes: yes, both load on demand.** With nothing loaded:
- `POST /v1/embeddings` for `text-embedding-nomic-embed-text-v1.5` → HTTP 200, 768 dims, 0.2 s.
  The embedding model did not show in `loaded_instances` afterwards.
- `POST /v1/chat/completions` for `google/gemma-3-4b` → HTTP 200, `"OK."`, 6.1 s. gemma then showed
  as loaded with `remaining_ttl_seconds: 3600`.

So a client doesn't have to call `models/load` first. It would call it to choose load settings, or to
load ahead of time so the first request isn't slow.

**A minimal HTTP client can cover LM Studio's model management: yes, as far as tested.** Three JSON
routes do it, with the same base URL and optional bearer token as `/v1`, and no websockets or
`lmstudio` SDK:
- `GET /api/v1/models`: list, type, loaded state, maximum context;
- `POST /api/v1/models/load`;
- `POST /api/v1/models/unload`.

Caveats: `context_length` may be ignored (6.2), and the auth-on behaviour is unverified (6.4).

## Verdicts

**(i) One `/v1` client for LM Studio, Ollama and `llama_xpc` embeddings with identical vectors: yes
for the client, unproven for identical vectors across servers.**
- Garage's own `LlamaXPCClient` is already that client:
  - against LM Studio it returns bit-identical vectors to the `openai` SDK;
  - it reads the same response shape as Ollama's `/v1/embeddings` (OpenAI shape) and `llama_xpc`.
- Not established:
  - whether Ollama's `/v1/embeddings` equals its `/api/embed` for a real embedding model (no
    embedding model is installed in Ollama here);
  - `llama_xpc`'s vectors (no model loaded).
- Vectors will **not** be identical across servers unless they run the same GGUF: LM Studio ships
  nomic as Q4_K_M, and Garage downloads Q8_0.
- The client must not delegate `dimensions` (LM Studio ignores it). Garage already truncates on its
  side.

**(ii) langextract through our OpenAI-shaped provider: yes, for both.**
- `LlamaXPCLanguageModel` with a `LlamaXPCClient` at `127.0.0.1:1234` (LM Studio, gemma-3-4b) and at
  `127.0.0.1:11434` (Ollama `/v1`, llama4) produced fully grounded extractions from Garage's prompt
  and examples.
- The Ollama `/v1` run matched today's `/api/generate` path fact for fact, in a third of the time.
- Two things to handle:
  - if JSON mode is ever requested, use `json_schema`, since LM Studio rejects `json_object`;
  - LM Studio's HTTP 200 error bodies (section 1).

**(iii) What would still need the `ollama` package or Ollama's own API: nothing Garage does today.**
- Embeddings, the "model present?" check and chat all map to `/v1` (section 5).
- Only these would still need Ollama's native API:
  - pulling models (`/api/pull`, not used; Garage only tells the user to run `ollama pull`);
  - richer model metadata (`/api/show`, `/api/tags` details);
  - load control (`keep_alive`, `/api/ps`, not used).
- The one open question is embedding parity, `/api/embed` vs `/v1/embeddings`, on a real
  embedding model. That needs a model pulled into Ollama first.

# Rebases onto main after PR #15

PR #15 was squash-merged into `main` as `0e0b7dc`. Each branch was rebased by replaying only its own
commits: `git rebase --onto origin/main $(git merge-base HEAD origin/claude/adoring-ritchie-c084cj)`.
2026-09-23 21:00–21:20 UTC. Note that `main` is not byte-for-byte the PR head: `git diff 97e3dd2
origin/main` shows 10 files changed, +134 / −1707.

## `claude/reset-xcuitest`: rebased, tested, pushed

- **Replayed:** `eb4bbfa` → `b3f2069`, `2f89694` → `9ae703c`, `2391b76` → `c08e1ab`, onto `0e0b7dc`.
  **No conflicts.** The merge-base with the PR branch was `97e3dd2`, and the earlier merge commits
  dropped out. The old head is kept locally as `backup/reset-xcuitest-pre-main-rebase`.
- **Tests on `c08e1ab`:**
  - `//macapp/Tests/GarageAppUnitTests:GarageAppUnitTests` passes: **260 tests, 0 failures**.
    `GarageAppGroupTests` 8/8, `ModelDownloadServiceTests` 4/4, `AppStateTests` 35/35.
  - `//ext/python:python_framework_codesign_test` passes (cached: its inputs are unchanged).
  - `//macapp/Tests/GarageAppResetUITests/...` builds.
- **Pushed** with `--force-with-lease` (expected `2391b76`): `origin/claude/reset-xcuitest` = **`c08e1ab`**.
- **The UI test was not run.** The rebase does not change the blocker from "Check of 898c0e6"
  (Task B):
  - `xcodebuild build-for-testing -scheme GarageAppResetUITests` now gets past the
    `python_framework.framework.zip` signing failure (fixed by `c08e1ab`). It then fails in Xcode's
    own `Validate` step on the app: `Framework …/Garage.app/Contents/Frameworks/PythonXPCService.framework
    contains Info.plist, expected Versions/Current/Resources/Info.plist since the platform does not
    use shallow bundles`.
  - rules_apple's `macos_framework` only builds flat frameworks, and `VALIDATE_PRODUCT=NO` does not
    skip that step. `aspect build` doesn't run it, which is why only the Xcode path fails.
  - Options (a decision for the owner, not made here): rewrite the framework into the versioned layout
    after rules_apple builds it; stop packaging PythonXPCService as a framework; or find another way
    past Xcode's validation. This also bears on `claude/store-sandbox-python`, which now ships
    `site-python` inside that framework.
  - Automation Mode was never reached, so no password prompt came up.

## `claude/awesome-gauss-9mc3jq`: rebase STOPPED on a conflict in logic both sides changed

- **Flattened first:** the branch brought in the first-run assistant through merge commit `6848049`,
  and that merge carried its port to the gRPC operations. A plain rebase drops merge commits, so
  `cfc752b` would have replayed unported. That merge was flattened into one ordinary commit (tree
  identical to `6848049`, crediting `cfc752b`'s author), with the nine later commits cherry-picked
  on top.
  - The flattened branch's tree equals the original tip exactly.
  - It is kept locally as `tmp-flat`, with a backup of the original at
    `backup/awesome-gauss-pre-main-rebase`.
- **The rebase onto `0e0b7dc` stopped at its first commit** (`9c7fc0d`, "Add an in-app bug reporter
  to GarageApp"), with conflicts in `GarageApp.swift` and `Views/ContentView.swift`. They are **not
  mechanical**:
  - `main` (from `898c0e6`) routes ⌘Q through `CommandGroup(replacing: .appTermination)` →
    `AppDelegate.quit()`. That posts `.garageWillQuit`, and `ContentView` answers by setting
    `isSplashPresented = false`, so SwiftUI stops re-attaching the splash before `terminate:` runs.
  - The branch replaced `isSplashPresented` with one `activeSheet: ActiveSheet?` (splash, bug
    report, and later the setup assistant, which takes the whole window). Its `present(_:)` swaps
    sheets through `nil` with a deferred task.
  - Combining them means deciding how quit dismisses an `activeSheet` (including cancelling a pending
    swap, which could re-present a sheet mid-quit), and whether the setup assistant counts.
  - The same seam comes back in later commits: the BugNub commit and the flattened assistant commit
    both rework `ContentView`'s body.
  - **A second overlap further down:** `main` has `AppState.terminateFromRunLoop` ("`NSApp.terminate`
    from the run loop rather than from inside a main-actor job"). That is the same deadlock fix as
    the branch's `40f04e3` ("Don't hang mid-quit after a database reset"), written independently, so
    one of the two must be chosen.
- **Aborted** with `git rebase --abort`. The branch is unchanged at its previous tip, now plus one new
  commit (below). Nothing was force-pushed.
- **CI's red checks on `c237061`:**
  - On the branch tip, `aspect gazelle` changes nothing.
  - `aspect buildifier` wanted only `ext/sparkle/BUILD.bazel` (`out` listed before `src` in three
    `native_binary` rules). That is committed as **`fb7e4c5`** on the branch, not pushed.
  - `aspect test //...` was not run, since the rebase was not completed.
