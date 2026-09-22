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
