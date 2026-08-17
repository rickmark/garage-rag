# Architecture

```
sources ──▶ walker ──▶ [materialize] ──▶ extract ──▶ quality gate
                                                          │
                            attribution ◀─────────────────┤
                                  │                       ▼
                                  └──────▶ documents ── chunks
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

### 7. Search (`search/hybrid.py`)

Reciprocal Rank Fusion over vector KNN and Postgres FTS, `k = 60`, 200
candidates per engine. RRF needs only each side's *ranking*, which matters
because cosine distance and `ts_rank_cd` are not comparably scaled.

The keyword half ORs its terms rather than ANDing them. `websearch_to_tsquery`
would require every word of "secure enclave firmware validation" in one chunk and
return nothing; RRF is what decides ordering, so the keyword side should favour
recall.

### 8. Serve (`mcp_server/server.py`)

MCP 2.0 over stdio. Every tool returns a dataclass, because under MCP 2.0
dataclass returns map field-for-field while scalars and lists get wrapped in
`{"result": ...}`.

## Idempotency

Two hashes, deliberately not redundant:

| Hash | Over | Enables |
|---|---|---|
| `source_sha256` | raw bytes | skip an unchanged file **without opening it** — and so without materializing a placeholder |
| `content_sha256` | extracted text | rebuild chunks when an extractor improves, even though the file never changed |

One transaction per document, so a crash leaves earlier documents committed.

## Deletion safety

The risk is not deleting, it is *deciding* something is missing — an unmounted
volume looks identical to a mass deletion. `ingest_runs.completed` marks only
walks that ran to exhaustion with no limit, `ingest_seen` records every URI
observed, and a run that would delete more than 25% of a source refuses without
`--force`.

## Concurrency

Extraction is CPU-bound and parallel across 10 of 16 cores, leaving headroom for
Postgres and Ollama. `OMP_THREAD_LIMIT=1` per worker, because Tesseract is
internally threaded and would otherwise oversubscribe.

Embedding is a single batching producer at 64 chunks per request: Ollama
serializes model execution, so client fan-out buys contention, not throughput.
