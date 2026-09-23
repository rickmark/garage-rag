---
layout: default
title: Architecture Guide
description: Ingestion pipeline, extractors, quality filtering, and concurrency model.
---

# Architecture

```
sources ──▶ walker ──▶ [materialize] ──▶ extract ──▶ quality gate
                                                          │
                            attribution ◀─────────────────┤
                                  │                       ▼
                                  └──────▶ documents ── chunks ◀── facts
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                        emb_bge_m3            emb_nomic_embed_text
                                              └───────────┬───────────┘
                                                          ▼
                                              hybrid search (RRF)
                                                          │
                                                    MCP server
```

## Stages

### 1. Walk (`ingest/walker.py`)

Stats each candidate once and yields a small record. Nothing is opened, because
opening is where the cost is — parsing, and for cloud placeholders, downloading.
Pruning happens during descent, so excluded subtrees are never entered:

- `DEFAULT_EXCLUDE_DIRS` — VCS, build output, dependency directories, test fixtures
- `DIAGNOSTIC_DIR_PATTERNS` — `sysdiagnose_*`, `*.logarchive`, `ioreg`, `logs`
- `DEPENDENCY_PATH_FRAGMENTS` — `go/pkg/mod`, `.cargo/registry`, and friends
- `include_code=False` (default) — source and config files are skipped

### 2. Materialize (`ingest/materialize.py`)

Cloud placeholders are zero-byte stubs; *reading* one asks the provider to
download it. Materialization is therefore metered by a `MaterializationBudget`
capping files and bytes per run. Hitting the cap is not a failure — because
ingest is idempotent, repeated bounded runs converge on the full corpus.

### 3. Extract (`extract/`)

Dispatch is by extension, with lazy imports so a walk over 100k files does not
pay for `pdfplumber` and `openpyxl` in every worker.

| Kind | Extractor | Notes |
|---|---|---|
| Markdown | `text.py` | YAML frontmatter split off; malformed frontmatter never costs the body |
| PDF | `pdf.py` | `pypdf` first, escalating to `pdfplumber` **per page** when a page yields little text or holds tables |
| Office | `office.py` | `python-docx` / `python-pptx` / `openpyxl`; headings preserved as Markdown |
| Images | `image.py` | Tesseract, escalating to Claude only when confidence is low *and* the source permits it |
| Code | `text.py` | Verbatim — indentation is meaningful |

### 4. Quality gate (`extract/quality.py`)

A personal corpus is full of text no human wrote. One macOS `sysdiagnose` bundle
here produced ~200k chunks — 76% of the index. Path rules catch most of it; this
module is the content-based backstop, using structural signals (line-shape
repetition, timestamp prefixes, hex/base64 density, alphabetic ratio).

Any single signal has false positives — a bibliography repeats, a cryptography
paper contains hex — so rejection needs either corroboration or one decisive
signal. Validated at zero false positives across 21 real prose documents.

`max_chunks_per_document` is the final backstop: no single document may dominate
the index.

### 5. Attribute (`attribute/`)

Signals in precedence order, each recording its evidence:

1. **Git history** (`git.py`) — authoritative, and the only signal that separates
   your own repository from a clone of someone else's.
2. **Embedded metadata** — PDF `/Author`, Office core properties. Filtered
   through `looks_like_tool_name`, because `python-pptx` writes its own author
   into every deck and `openpyxl` names itself.
3. **Path convention** (`pathrules.py`) — always available, so it is the
   fallback rather than the lead.
4. **Source default.**

> **Why one `git log` per repository:** `git log --follow` per file would mean
> 18k git invocations. One `--name-only` pass per repo builds a path→authors map
> in memory: 60 repos, 29 seconds total, versus an afternoon.

### 6. Store

See [`schema.md`](schema.md). Chunks are model-agnostic; each embedding model
owns a table keyed on `chunk_id` with `ON DELETE CASCADE`.

### 7. Distill facts (`enrich/facts.py`)

An optional pass over stored documents, run as `garage enrich-facts` or the
`EnrichFacts` streaming RPC (the app's Enrich Facts action), not part of ingest
itself. [LangExtract](https://github.com/google/langextract) is pointed at the
local model named by `facts.model` on `facts.provider` (default: the app's
`gemma2-2b` alias on `llama_xpc`; `ollama` with e.g. `gemma2:2b` is the other
option, and `--model`/`--provider` override both) with a deliberately generic prompt —
the module has no notion of what kind of document it is given — and asks for
every standalone claim in the document's own wording. `model_id`/`model_url`
are always passed explicitly because `lx.extract` otherwise defaults to a cloud
Gemini model; like the rest of local inference, content never leaves the
machine.

Each fact lands in `facts` grounded to the exact span of `documents.content`
it came from; a fact the extractor cannot locate is dropped rather than stored.
Facts for a document are replaced wholesale on re-extraction.

Every fact also gets a `chunks` row of its own (`chunks.fact_id`,
`chunker = 'facts:langextract:<model>'`). That is the entire embedding story: a
chunk is a chunk regardless of where its text came from, so the ordinary
backfill anti-join picks fact chunks up and every registered model ends up with
a vector for them, with no fact-specific embedding path. Deleting a fact
cascades into its chunk and, from there, into every `emb_*` table.

### 8. Search (`search/hybrid.py`)

Reciprocal Rank Fusion over vector KNN and Postgres FTS, `k = 60`, 200
candidates per engine. RRF needs only each side's *ranking*, which matters
because cosine distance and `ts_rank_cd` are not comparably scaled.

The keyword half ORs its terms rather than ANDing them. `websearch_to_tsquery`
would require every word of "secure enclave firmware validation" in one chunk and
return nothing; RRF is what decides ordering, so the keyword side should favour
recall.

### 9. Serve (`mcp_server/server.py`)

MCP 2.0 over stdio (`garage-mcp`, the entry point clients spawn, separate from
the `garage` CLI) or HTTP (`garage mcp-serve`, or the macOS app's MCP helper).
Every tool returns a dataclass, because under MCP 2.0
dataclass returns map field-for-field while scalars and lists get wrapped in
`{"result": ...}`. `rag_search`, `rag_get_document`, `rag_list_sources`,
`rag_list_authors` and `rag_stats` read the corpus; `rag_ask` and
`rag_generate` also generate text, entirely on a local model.

`rag_ask` runs the same retrieval as `rag_search`, numbers the excerpts (each
trimmed to ~1,200 characters), and asks the model to answer from them citing
`[n]`; the result carries the answer plus one `Citation` per excerpt so a client
can resolve `[n]` back to a document. `rag_generate` is the same model with a raw
prompt and no retrieval. The model is `LocalChatModel` (`enrich/generation.py`),
built from `facts.provider` / `facts.model`: `llama_xpc` posts to the app's
`LlamaXPCService` on `llama_host` (the `model` field of each request selects
among the models the engine holds), `ollama` to a local Ollama server on
`ollama_host`. Neither is a cloud API; retrieved communications may appear in the
prompt but never leave the machine (see `docs/privacy.md`). `garage ask` is the
CLI front door to both tools, with `--json` for the app.

## Idempotency

Two hashes, deliberately not redundant:

| Hash | Over | Enables |
|---|---|---|
| `source_sha256` | raw bytes | skip an unchanged file **without opening it** — and so without materializing a placeholder |
| `content_sha256` | extracted text | rebuild chunks when an extractor improves, even though the file never changed |

One transaction per document, so a crash leaves earlier documents committed.

Each document also records a chunker signature (`chunks.chunker`, e.g.
`recursive:1000/100` or `code:python:1500/150`); a different signature means the
chunks are rebuilt on the next ingest even when neither hash changed. The
splitters behind it (`ingest/splitters.py`) are a small dependency-free port of
the langchain-text-splitters behaviour the chunker was first written against.
`tests/test_chunking_golden.py` pins their output to what langchain produced,
chunk for chunk and offset for offset, so the signatures did not change with the
swap and an existing index is not rebuilt. A deliberate change to the splitting
must change the signature too, so that stored chunks are rebuilt rather than
silently mixed.

## Deletion safety

The risk is not deleting, it is *deciding* something is missing — an unmounted
volume looks identical to a mass deletion. `ingest_runs.completed` marks only
walks that ran to exhaustion (a `--limit` or a cancellation that stopped the
walk early leaves it false), `ingest_seen` records every URI the walk yielded —
indexed, stat-skipped, failed or placeholder alike — and a run that would delete
more than 25% of a source refuses without `--force`.

## Concurrency

Ingest is a single process that handles one file at a time: walk, materialize,
extract, chunk and store run sequentially, one transaction per document. The
only worker thread is the one that guards a placeholder download with a
timeout. Parallelism across sources comes from running separate ingest
invocations, not from a pool inside the pipeline.

Embedding is a single batching producer at 64 chunks per request: Ollama
serializes model execution, so client fan-out buys contention, not throughput.
The `llama_xpc` provider (embeddings and, with `--provider llama_xpc`, facts)
talks to the app's `LlamaXPCService` over loopback HTTP (`llama_host`, a
llama-server-compatible API); the app loads and unloads models over XPC, so
the Python side is a plain client with no model lifecycle of its own.
