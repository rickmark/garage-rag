---
layout: default
title: Support & User Guide
description: Complete user and support guide for Garage macOS App, CLI, ingestion pipelines, and MCP integration.
---

# Garage Support & User Guide

Welcome to the comprehensive support guide for **Garage**. This guide covers system requirements, installation, source management, model configuration, MCP server integrations, and database operations.

---

## Table of Contents
1. [System Requirements](#system-requirements)
2. [Getting Started](#getting-started)
   - [Native macOS Application (GarageApp)](#native-macos-application)
   - [Command Line Interface (CLI)](#command-line-interface)
3. [Managing Sources & Ingestion](#managing-sources--ingestion)
   - [Corpus Classes & Trust Tiers](#corpus-classes--trust-tiers)
   - [Adding Folders, Repositories, and Mail/Messages](#adding-sources)
4. [Embedding Models & Providers](#models-and-embeddings)
   - [Ollama Configuration](#ollama-configuration)
   - [LM Studio Configuration & Keychain Tokens](#lm-studio-configuration)
5. [Model Context Protocol (MCP) Integration](#mcp-integration)
   - [Claude Desktop Integration](#claude-desktop-integration)
   - [Claude Code Integration](#claude-code-integration)
   - [HTTP MCP Endpoint](#http-mcp-endpoint)
6. [macOS Permissions & TCC](#macos-permissions)
7. [Database Backup, Restore & Reset](#database-management)

---

<h2 id="system-requirements">1. System Requirements</h2>

- **Operating System**: macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia)
- **Architecture**: Apple Silicon (M1/M2/M3/M4) only; Intel Macs are not supported
- **Memory**: 8 GB RAM minimum (16 GB+ recommended when running local embedding models)
- **Disk Space**: ~500 MB for Garage application and embedded PostgreSQL; database size depends on ingested document corpus
- **Embedding Backend**: [Ollama](https://ollama.com/) or [LM Studio](https://lmstudio.ai/) running locally

---

<h2 id="getting-started">2. Getting Started</h2>

### Native macOS Application (`GarageApp`)

`GarageApp` provides a menu bar utility and management window that bundles an embedded, relocatable instance of PostgreSQL 18 with `pgvector`:

1. **Launch GarageApp**: The app initializes its private database in `~/Library/Application Support/GarageApp/pgdata` on port `14824`. A strong SCRAM superuser password is automatically generated and securely stored in your **macOS Keychain**.
2. **Menu Bar Status**: Look for the Garage icon in your macOS menu bar. A green status indicator confirms that PostgreSQL and the local MCP HTTP service are active.
3. **Open Management Window**: Click the menu bar icon and select **Open Garage** to view Sources, Models, Logs, and Search.

### Command Line Interface (`garage`)

For automated pipelines or terminal workflows, the `garage` CLI communicates with the database:

```bash
# Initialize local configuration in ~/.garage.json
garage config init

# Initialize the schema and pgvector extension
garage init-db

# Check status and document count
garage stats
```

---

<h2 id="managing-sources--ingestion">3. Managing Sources & Ingestion</h2>

Garage indexes your local files, codebases, notes, and messages into a unified vector corpus.

### Corpus Classes & Trust Tiers

Every source is categorized to protect privacy and enable precise retrieval filtering:

- **Corpus Classes**:
  - `document`: Prose documents, research papers, reports, notes (`.md`, `.pdf`, `.docx`, `.pptx`, `.xlsx`, OCR images).
  - `code`: Source code repositories and structured configuration files (`.json`, `.yaml`, `.toml`, `.py`, `.swift`, `.ts`, etc.).
  - `communication`: Personal conversations (Apple Messages, Mail). **Enforced strictly with zero cloud egress**.
- **Trust Tiers**:
  - `authored`: Content written by you (verified via Git commit authorship or your identity profiles).
  - `reference`: External material you collected (papers, vendored packages, documentation).
  - `received`: Inbound communications sent by other parties.

### Adding Sources

```bash
# Add a personal notes directory as authored content
garage add-source notes ~/Documents/Notes --class document --trust authored

# Add a Git repository (authorship is detected per-commit automatically)
garage add-source my-repo ~/Projects/my-repo --class code

# Add Apple Messages database (requires Full Disk Access)
garage add-source imessage ~/Library/Messages --class communication

# Run ingestion to parse files into text chunks
garage ingest
```

---

<h2 id="models-and-embeddings">4. Embedding Models & Providers</h2>

Garage supports multiple embedding models simultaneously without re-parsing raw files.

### Ollama Configuration

1. Install and start [Ollama](https://ollama.com/):
   ```bash
   ollama pull bge-m3
   ```
2. Register and set `bge-m3` as the default model:
   ```bash
   garage register-model bge-m3 --provider ollama --dims 1024
   garage set-default-model bge-m3
   ```
3. Generate vector embeddings for all indexed chunks:
   ```bash
   garage backfill
   ```

### LM Studio Configuration

1. In LM Studio, load an embedding model (e.g., `nomic-ai/nomic-embed-text-v1.5-GGUF`) and start the local server on `http://127.0.0.1:1234`.
2. In `GarageApp` under the **Models** tab, select LM Studio as the provider and optionally store your LM Studio API token in the macOS Keychain.
3. Via CLI:
   ```bash
   garage register-model nomic-embed-text --provider lmstudio --dims 768
   garage backfill
   ```

---

<h2 id="mcp-integration">5. Model Context Protocol (MCP) Integration</h2>

Garage implements the **Model Context Protocol (MCP) 2.0**, allowing AI assistants to query your local knowledge base.

### Claude Desktop Integration

Install the Garage MCP tool directly into your Claude Desktop configuration:

```bash
garage mcp-install --target claude-desktop
```

This updates `~/Library/Application Support/Claude/claude_desktop_config.json` with the required command and database connection environment. Restart Claude Desktop to start searching your notes and code directly from Claude!

### Claude Code Integration

Register Garage with Claude Code:

```bash
garage mcp-install --target claude-code-user
```

### HTTP MCP Endpoint

`GarageApp` automatically hosts a loopback HTTP MCP server at:
`http://127.0.0.1:8787/mcp`

<div class="callout callout-info">
  <div class="callout-title">🔒 Security Notice</div>
  <p>The HTTP MCP server strictly binds to <code>127.0.0.1</code> with built-in DNS-rebinding protection and host validation. It will refuse remote bindings to protect your personal data.</p>
</div>

---

<h2 id="macos-permissions">6. macOS Permissions & TCC</h2>

When indexing Apple Messages (`~/Library/Messages`) or Apple Mail (`~/Library/Mail`), macOS Transparency, Consent, and Control (TCC) requires explicit permission.

### Granting Full Disk Access

1. Open **System Settings** on your Mac.
2. Navigate to **Privacy & Security → Full Disk Access**.
3. Click the **+** button and add **GarageApp** (or your **Terminal** app if running via CLI).
4. Toggle the switch to **On**.
5. Restart `GarageApp` or run `garage ingest` again.

---

<h2 id="database-management">7. Database Backup, Restore & Reset</h2>

### Backup & Restore
- **In GarageApp**: Open the **Status** view and click **Backup Database** to export a PostgreSQL custom-format snapshot (`.dump`). To restore from a previous backup, click **Restore Database**.
- **Via CLI**:
  ```bash
  # Backup
  pg_dump -Fc -d "postgresql://garage:$(security find-generic-password -s garage_postgres_super -w)@127.0.0.1:14824/garage-rag" -f ~/Desktop/garage_backup.dump

  # Reset: there is no reset flag. Drop the schema, then re-apply it.
  psql -d "postgresql://garage:$(security find-generic-password -s garage_postgres_super -w)@127.0.0.1:14824/garage-rag" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
  garage init-db
  ```

---

<div class="callout callout-success">
  <div class="callout-title">Need additional assistance?</div>
  <p>If you encounter unexpected errors or need further diagnosis, check out the <a href="{{ '/troubleshooting.html' | relative_url }}">Troubleshooting Guide</a> or <a href="{{ '/contact.html' | relative_url }}">open an issue on GitHub</a>.</p>
</div>
