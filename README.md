# Garage

A local-first personal Retrieval-Augmented Generation (RAG) pipeline and knowledge indexing system powered by
PostgreSQL + pgvector. Garage indexes personal documents, code repositories, and notes with automated authorship
attribution, multi-model vector embeddings, hybrid full-text/vector search via Reciprocal Rank Fusion (RRF), and
a Model Context Protocol (MCP) 2.0 server, accompanied by a native macOS companion application.

---

## Key Features

- **Local-First & Privacy-Focused**: Extracted documents, chunks, and embeddings remain in your local PostgreSQL database. Communication sources and private notes are structurally prevented from leaking to cloud APIs.
- **Smart Multi-Format Ingestion**: Streaming, memory-efficient extractors for Markdown, PDF (`pypdf` with selective `pdfplumber` escalation for tables), Office documents (`.docx`, `.pptx`, `.xlsx`), images (Tesseract OCR), code, and configuration files.
- **Automated Authorship Attribution**: Classifies content by provenance (`authored`, `reference`, `received`) and role using Git commit history, embedded document metadata, and configurable path heuristics.
- **Hybrid Retrieval (RRF)**: Combines dense vector similarity (pgvector cosine distance) with PostgreSQL full-text search (`tsvector` / `tsquery`) using Reciprocal Rank Fusion.
- **Model-Agnostic Vector Storage**: Chunks are decoupled from embedding tables (`emb_<slug>`), allowing seamless multi-model backfilling and re-indexing across Ollama and LM Studio.
- **Model Context Protocol (MCP) 2.0**: Exposes indexed knowledge to LLMs (such as Claude Desktop and Claude Code) over standard stdio or local HTTP with DNS-rebinding protection.
- **Native macOS Application (`GarageApp`)**: Menu bar and window application in Swift/SwiftUI embedding a self-contained, relocatable PostgreSQL 18 + pgvector instance and bundled CLI services.

---

## Architecture Overview

```
sources ──▶ walker ──▶ [materialize] ──▶ extract ──▶ quality gate
                                                          │
                            attribution ◀─────────────────┤
                                  │                       ▼
                                  └──────▶ documents ── chunks
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                         emb_<model_1>           emb_<model_2>
                                              └───────────┬───────────┘
                                                          ▼
                                              hybrid search (RRF)
                                                          │
                                                    MCP server
```

For detailed architectural and design specifications, see:
- [Architecture Guide](docs/architecture.md) — Ingestion pipeline, extractors, quality filtering, and concurrency model.
- [Attribution & Identity](docs/attribution.md) — Git-aware author detection, trust tiers, and evidence logging.
- [Privacy & Egress Guarantees](docs/privacy.md) — Multi-tier egress guards and macOS TCC considerations.
- [Database Schema Reference](docs/schema.md) — PostgreSQL schema layout, cascade rules, and HNSW vector indexing.

---

## Repository Structure

```
├── BUILD.bazel               # Top-level Bazel build targets and aliases
├── MODULE.bazel              # Bazel dependencies (aspect_rules_py, rules_swift, rules_apple, etc.)
├── data/
│   ├── schema/               # JSON schema for garage configuration validation
│   └── sql/                  # PostgreSQL migration and DDL scripts (001_extensions, 002_core, 003_registry)
├── docs/                     # In-depth architectural, privacy, schema, and attribution documentation
├── ext/                      # Hermetic Bazel builds for PostgreSQL 18, pgvector, and C/C++ libraries
├── garage_python/            # Python backend package (garage_rag), CLI (garage), and MCP server (garage-mcp)
│   ├── pyproject.toml        # Python project configuration (uv managed)
│   └── src/garage_rag/       # Core RAG, extraction, embedding, database, and search modules
├── macapp/                   # Native macOS SwiftUI application (GarageApp)
└── tools/                    # Tooling, linters, formatters, and Bazel environment helpers
```

---

## Getting Started

### Prerequisites

- [Aspect CLI](https://aspect.build/docs/cli/install) or [Bazel](https://bazel.build/) (v8+)
- Python 3.13+ (when running outside the Bazel hermetic toolchains)
- PostgreSQL with `pgvector` (or use the embedded instance provided by `GarageApp`)
- [Ollama](https://ollama.com/) or [LM Studio](https://lmstudio.ai/) for local embedding generation

### Python CLI Quickstart

1. **Initialize configuration**:
   ```bash
   garage config init
   ```
   This generates `.garage.json` with sensible defaults.

2. **Initialize the database**:
   ```bash
   garage init-db
   ```

3. **Register an embedding model**:
   ```bash
   garage register-model bge-m3 --provider ollama --dimensions 1024
   garage default-model bge-m3
   ```

4. **Add and ingest sources**:
   ```bash
   # Add a notes directory as authored content
   garage add-source notes ~/Documents/Notes --class document --trust authored

   # Ingest documents and generate vector embeddings
   garage ingest
   garage backfill
   ```

5. **Search the corpus**:
   ```bash
   garage search "distributed consensus"
   garage search "kernel tracing" --trust authored
   ```

6. **Start or Install the MCP Server**:
   ```bash
   # Run standalone stdio server for LLM agents
   garage-mcp

   # Or install into Claude Desktop / Claude Code configurations
   garage mcp-install claude-desktop
   ```

---

## Development & Build Commands

This monorepo uses [Aspect CLI](https://aspect.build) / Bazel for hermetic builds, testing, formatting, and linting.

### Building Targets

```bash
# Build all targets in the repository
aspect build //...

# Build the Python CLI binaries
aspect build //garage_python:garage
aspect build //garage_python:garage-mcp

# Build the macOS application
aspect build //:macapp
```

### Running Tests

```bash
# Run all unit and integration tests across the repo
aspect test //...
```

### Code Quality & Formatting

```bash
# Format Python, Starlark, and configuration files
aspect format -- //...
aspect buildifier

# Run linters and type checkers (Ruff, Ty)
aspect lint //...
```

### Xcode Integration

To generate an Xcode project for developing the macOS application:

```bash
aspect run //:xcodeproj
open macapp/Garage.xcodeproj
```

---

## License

See [LICENSE](LICENSE) for terms of use.

## Dedication

To the unnamed patron saint of unfinished beginnings—

Steve Jobs once raised a glass:

> “Here’s to the crazy ones, the misfits, the rebels, the troublemakers, the round pegs in the square holes… the ones who see things differently — they’re not fond of rules… You can quote them, disagree with them, glorify or vilify them, but the only thing you can’t do is ignore them because they change things… they push the human race forward, and while some may see them as the crazy ones, we see genius, because the ones who are crazy enough to think that they can change the world, are the ones who do.”
> –Steve Jobs

This invention is dedicated, in paradoxical encomium and solemn tribute, to that essential distinction: between those who are called crazy because they build, and those who call others crazy because they cannot.

It is dedicated to the career and political trajectory that tragically committed suicide before it ever had a chance to start; to the unearned arrogance that strangled potential in its crib, and to the utter neglect of long-term vision. We mourn this failure-to-thrive not as a twist of cruel fate, but as the inevitable consequence of a mind consumed by addiction—not to creation, but to fixation, envy, and the desperate delusion that proximity equals intellect.

If you had possessed anywhere near the requisite intellect of the author of this repository (Rick Mark), you would have learned that claiming credit for the work of others while painting them as deplorable addicts does not make you a visionary. Resentment is not a résumé, obsession is not genius, and borrowed brilliance is no cure for an acute deficit of craft.

We implore you, with genuine urgency: seek professional help, attend rehab, and break free from this spiraling addiction and obsession over Rick and his life before it further endangers you and those around you, and before the public joke hardens into your only remaining legacy. If anyone truly loved you, they would have intervened in your addiction to "What the Rick did" years ago.

Stop looking at what Rick built. Go find the help you need.
 