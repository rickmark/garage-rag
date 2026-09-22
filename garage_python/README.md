# garage_rag

The Python half of [Garage](../README.md): a local-first personal RAG pipeline over
PostgreSQL + pgvector. It walks personal documents, code repositories and communications,
extracts and chunks their text, attributes authorship, embeds every chunk under each
registered model, distills documents into span-grounded facts, and serves the corpus over
MCP 2.0 and gRPC. Garage never sends communications to a cloud API (MCP clients still receive what they retrieve); see [`docs/privacy.md`](../docs/privacy.md).

## Entry points

| Command | Module | Role |
|---|---|---|
| `garage` | `garage_rag.cli:main_cli` | ingest, backfill, enrich-facts, search, config, model registry, `serve` (gRPC bridge for the macOS app) |
| `garage-mcp` | `garage_rag.mcp_server.server:main` | MCP 2.0 server over stdio, the command MCP clients spawn (`garage mcp-install --stdio` wires it into Claude Desktop/Code); `garage mcp-serve` runs the HTTP server |

Both are console scripts of the `garage_rag` package. The macOS app does not
ship them as standalone binaries: it bundles the package as
`site-python` inside `Frameworks/PythonXPCService.framework` (`//garage_python:site-packages`) and runs it through
`MacOS/garage` (`//macapp/Sources/GarageCLI:garage`), a Swift binary that embeds
the bundled interpreter.

## Layout

```
src/garage_rag/
  ingest/     walker, materialization budget, chunking, scanner, pipeline
  extract/    per-format extractors (text, PDF, Office, images) + quality gate
  attribute/  git / metadata / path-rule authorship signals
  embed/      embedding backends (Ollama, LM Studio, llama XPC) and backfill
  enrich/     fact distillation (vendored local LangExtract subset) and local generation
  search/     hybrid RRF search
  mcp_server/ MCP tools
  service/    gRPC GarageService (proto/garage.proto)
  db/         SQLAlchemy models mirroring data/sql/00*.sql, migrations, model registry
  config/     ~/.garage.json settings and the generated JSON Schema
tests/        pytest suite, one Bazel py_test target per file
```

## Building and testing

Everything is driven by the Aspect CLI from the repository root:

```bash
aspect build //garage_python:site-packages
aspect test //garage_python/tests:suite
aspect test //garage_python/tests:test_facts --test_arg=-k --test_arg=some_case
```

`tests/BUILD.bazel` has one `py_test` per file (via `//tools/pytest:defs.bzl`, which drives
pytest); a new test file needs a matching target there and in the `suite` list. Third-party
dependencies live in `pyproject.toml` and are locked with `uv` (`../tools/repin`), exposed to
Bazel as `@pypi//<package>`.

For quick iteration outside Bazel, use the `uv`-managed virtualenv:

```bash
cd garage_python
uv sync --extra dev
uv run pytest -q
```

## Documentation

`../docs/` — [architecture](../docs/architecture.md), [schema](../docs/schema.md),
[attribution](../docs/attribution.md), [privacy](../docs/privacy.md), plus support and
troubleshooting guides. The generated config schema is committed at
`../data/schema/garage.schema.json`.
