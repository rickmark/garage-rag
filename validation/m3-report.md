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
