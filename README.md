# garage-rag

A local-first personal RAG pipeline. Indexes your own documents — Markdown, PDF,
Office, images, git repositories, and private communications — into Postgres with
`pgvector`, and exposes the result to Claude through an MCP server.

Everything that can run locally does: embeddings via Ollama, OCR via Tesseract,
search entirely in Postgres. The only optional cloud call is an OCR fallback for
images Tesseract cannot read, and it is **structurally blocked** from ever seeing
private communications.

## What makes it different from a generic vector store

Three distinctions the filesystem loses, preserved as first-class schema:

| Tier | Meaning |
|---|---|
| `authored` | You wrote it. Derived from git history, PDF metadata, or path convention. |
| `reference` | Downloaded material you have already QA'ed. Treated as high trust. |
| `communication` | Exchanged between people. Sender/recipient modeled; never leaves the machine. |

Search can be filtered by tier, so "what did *I* conclude about X" and "what does
my *reference* material say about X" are different queries.

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
garage add-source dropbox ~/Dropbox --trust authored
garage ingest --source dropbox
garage search "what did I conclude about boot security"
```

Then register the MCP server with Claude Code:

```bash
claude mcp add garage-rag -- garage-mcp
```

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
