# garage-rag

A local-first personal RAG pipeline. Indexes your own documents — Markdown, PDF,
Office, images, git repositories, and private communications — into Postgres with
`pgvector`, and exposes the result to Claude through an MCP server.

Everything that can run locally does: embeddings via Ollama, OCR via Tesseract,
search entirely in Postgres. The only optional cloud call is an OCR fallback for
images Tesseract cannot read, and it is **structurally blocked** from ever seeing
private communications.

## What makes it different from a generic vector store

Two independent axes the filesystem loses, preserved as first-class schema.

**What a thing is** (`corpus_class`):

| Value | Meaning |
|---|---|
| `document` | Prose: notes, papers, reports, presentations |
| `code` | Source and structured config |
| `communication` | Messages and mail. Never leaves the machine. |

**How trusted it is** (`trust_tier`):

| Value | Meaning |
|---|---|
| `authored` | You wrote it — from git history, document metadata, or path convention |
| `reference` | External material already QA'ed. High trust. |
| `received` | Someone else sent it to you |

Keeping these separate is what makes the corpus queryable. `(code, reference)` is
a vendored dependency; `(code, authored)` is your own work; `(document,
reference)` is a downloaded paper. So "what did *I* conclude about X" and "what
does my *reference* material say about X" are genuinely different queries:

```bash
garage search "boot security" --trust authored
garage search "boot security" --trust reference --class document
```

## Requirements

- macOS (developed on macOS 26, Apple Silicon)
- Postgres 17+ with `pgvector` — `brew install postgresql@18 pgvector`
- [Ollama](https://ollama.com) for local embeddings
- Tesseract for OCR — `brew install tesseract`
- Python 3.13 or 3.14, and [`uv`](https://docs.astral.sh/uv/)

## Install

```bash
brew install postgresql@18 pgvector tesseract ollama
brew services start postgresql@18
brew services start ollama

createdb rag
ollama pull bge-m3            # 1024-dim, MIT, strong general-purpose retrieval

git clone <this repo> && cd garage
uv venv --python 3.14
uv pip install -e '.[dev]'
```

Optional cloud OCR fallback: `uv pip install -e '.[cloud]'` and set
`ANTHROPIC_API_KEY`.

## Quick start

```bash
cp .env.example .env          # then edit: set GARAGE_SELF_NAME and identities

garage init-db                # apply schema, install extensions
garage register-model bge-m3  # creates emb_bge_m3 + HNSW index

garage add-source notes ~/Documents --class document --trust authored
garage ingest --source notes  # documents only; add --include-code for source
garage backfill               # embed anything not yet embedded
garage search "what did I conclude about boot security"
```

Then register the MCP server with a client:

```bash
garage mcp-install                      # writes ./.mcp.json (Claude Code, this project)
garage mcp-install -t claude-desktop    # or lmstudio | cursor | vscode
garage mcp-install --dry-run            # show the JSON without writing
garage mcp-status                       # which clients are registered
garage mcp-uninstall                    # remove the entry again
```

The config is **merged**, not replaced: other servers and unrelated top-level
keys survive, the previous file is backed up, and the write is atomic. An
existing entry of the same name is never overwritten without `--force`.

The entry points at your `.env` via `GARAGE_ENV_FILE` rather than copying its
values, so editing `.env` takes effect without re-installing:

```json
{
  "mcpServers": {
    "garage-rag": {
      "command": "/path/to/garage/.venv/bin/garage-mcp",
      "args": [],
      "env": { "GARAGE_ENV_FILE": "/path/to/garage/.env" }
    }
  }
}
```

> Paths are absolute, because a client launches the server with its own `PATH`
> that will not include this virtualenv. That also means a committed `.mcp.json`
> will not resolve on someone else's machine — they should run `garage
> mcp-install` themselves.

### Transports

`stdio` is the default: the client spawns the server and talks over the pipe. One
process per client, lifetime managed for you.

`--http` serves the modern `streamable-http` transport instead, which is what you
want to share one long-running server between several clients, or to reach the
corpus from a container or another host:

```bash
garage mcp-serve --http                       # http://127.0.0.1:8787/mcp
garage mcp-serve --http --port 9000 --path /rag
garage mcp-serve --sse                        # legacy SSE transport
garage mcp-install --http                     # register the URL rather than a command
```

With `--http` the client only *connects*; keeping the process alive is your job
(launchd, tmux, a container). The registered entry looks like:

```json
{ "mcpServers": { "garage-rag": { "type": "http", "url": "http://127.0.0.1:8787/mcp" } } }
```

> **This server has no authentication and answers questions about your entire
> corpus.** It therefore binds `127.0.0.1` only, and refuses a non-loopback
> address unless you pass `--allow-remote`. If you do expose it, put an
> authenticating reverse proxy in front. DNS-rebinding protection is always on, so
> a forged `Host` header is rejected with `421` — without it, a page in your
> browser could reach a loopback-bound server and read your documents.

## Multiple embedding models

Chunks are stored once, model-agnostically. Each embedding model gets its own
table keyed on `chunk_id`, so adding a model is a pure backfill that never
touches existing vectors or re-reads your files:

```bash
garage register-model nomic-embed-text   # fast, 768-dim
garage register-model qwen3-embedding-4b # higher quality, 2560-dim
garage backfill --model qwen3-embedding-4b
garage search "..." --model qwen3-embedding-4b
```

Storage type is chosen automatically from the model's width, because `pgvector`'s
HNSW index has hard ceilings — 2000 dimensions for `vector`, 4000 for `halfvec`:

| Model width | Storage | Index |
|---|---|---|
| ≤ 2000 | `vector(d)` | HNSW, cosine |
| 2001–4000 | `halfvec(d)` | HNSW, cosine |
| > 4000, Matryoshka-trained | `halfvec(4000)`, truncated | HNSW, cosine |
| > 4000, not Matryoshka | `vector(d)` | HNSW on `binary_quantize(...)`, re-ranked on exact cosine |

## Idempotency

Re-running `garage ingest` re-indexes and replaces; it does not duplicate.
Two hashes drive this:

- `source_sha256` (raw bytes) — lets an unchanged file be skipped *without being
  read or parsed*.
- `content_sha256` (extracted text) — decides whether chunks must be rebuilt, so
  upgrading an extractor correctly triggers re-chunking even though the file on
  disk never changed.

Deleted files are reconciled only from scans that **completed**, tracked in
`ingest_runs`. Without that guard, an unmounted Dropbox would look like thousands
of deletions.

## Cloud placeholders

Dropbox, iCloud Drive, and OneDrive leave **zero-byte stubs** for files that live
only in the cloud. They look like real files in a listing, and *reading* one asks
the provider to download it — so a naive walk over an online-only folder silently
becomes a multi-hundred-gigabyte transfer.

Placeholders are detected (`com.dropbox.placeholder` xattr, `SF_DATALESS` flag,
`.name.icloud` sidecars) and reported distinctly from genuinely empty files.
Downloading them is opt-in and metered:

```bash
GARAGE_MATERIALIZE_PLACEHOLDERS=true
GARAGE_MATERIALIZE_LIMIT=2000          # files per run
GARAGE_MATERIALIZE_MAX_BYTES=21474836480
```

Hitting the cap is not a failure. Because ingest is idempotent, repeated bounded
runs converge on the full corpus instead of one unbounded pass.

## Machine-generated text

A personal corpus is full of text nobody wrote. During development one macOS
`sysdiagnose` bundle produced **~200k chunks — 76% of the entire index**. That is
not merely wasteful: near-duplicate log lines compete with real prose at query
time, so retrieval degrades as the corpus grows.

Three defences, in order of reliability:

1. **Path and filename rules** — `sysdiagnose_*`, `*.logarchive`, `ioreg`,
   `*.hash.txt`, dependency caches (`go/pkg/mod`), test fixtures (`testdata/`).
2. **Content heuristics** (`extract/quality.py`) — line-shape repetition,
   timestamp prefixes, hex/base64 density. Requires corroboration before
   rejecting, and is validated at zero false positives on real prose.
3. **`max_chunks_per_document`** — no single document may dominate the index.

Measured effect on `~/Developer`: 39,281 documents / 707,917 chunks →
4,577 / 60,748.

## Privacy

`trust_tier = 'communication'` content never reaches a cloud API. Enforced at
four levels rather than by convention:

1. `enrich/egress.py` is the only module that constructs an Anthropic client.
2. The request payload type *requires* a trust tier and raises `EgressBlocked`
   when it is `communication` — there is no way to build a request without
   declaring one.
3. `sources.allow_cloud_enrichment` defaults to false and stays false for
   Messages and Mail.
4. `tests/test_egress_block.py` asserts both the raise and that no module outside
   `enrich/` imports `anthropic`.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — pipeline stages and data flow
- [`docs/schema.md`](docs/schema.md) — table-by-table reference
- [`docs/attribution.md`](docs/attribution.md) — how authorship and trust are decided
- [`docs/privacy.md`](docs/privacy.md) — egress control and macOS permissions

## License

MIT — see [LICENSE](LICENSE).
