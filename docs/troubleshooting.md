---
layout: default
title: Troubleshooting & Diagnostics
description: Resolutions for common issues, error codes, PostgreSQL startup failures, and permission problems in Garage.
---

# Troubleshooting & Diagnostics

This guide provides step-by-step diagnostic procedures and solutions for common issues encountered when using Garage.

---

## Quick Diagnostic Matrix

| Symptom / Error | Probable Cause | Quick Fix |
|---|---|---|
| `authorization denied` or `Operation not permitted` | Missing macOS Full Disk Access for Messages or Mail | [Grant Full Disk Access](#tcc-permissions) |
| `FATAL: lock file "postmaster.pid" already exists` | Orphaned lock file after system crash | [Clear PID Lock File](#postgres-pid-lock) |
| `FATAL: postmaster became multithreaded during startup` | Locale initialization spawning threads | [Set `LC_ALL=C`](#postgres-multithreaded) |
| `connection refused to 127.0.0.1:14824` | PostgreSQL service not running or port occupied | [Restart Postgres Service](#postgres-port-issues) |
| `HTTP 421 Misdirected Request` on MCP server | DNS rebinding protection triggered | [Check Host Header](#mcp-dns-rebinding) |
| `Vector dimension mismatch` on backfill | Registered model dimension differs from provider | [Verify Model Dimensions](#vector-dimensions) |
| Large unexpected network downloads | Cloud stubs (Dropbox/iCloud) being read | [Configure Placeholder Limits](#cloud-placeholders) |

---

<h2 id="postgres-issues">1. PostgreSQL Service Issues</h2>

<h3 id="postgres-port-issues">Port 14824 Unavailable</h3>

**Symptom**: GarageApp indicates database error or CLI fails with:
`psycopg2.OperationalError: could not connect to server: Connection refused`

**Solution**:
1. Check if another instance or zombie process is using port 14824:
   ```bash
   lsof -i :14824
   ```
2. If a stale postgres process exists, stop it:
   ```bash
   kill -TERM <PID>
   ```
3. In `GarageApp`, click the menu bar icon and choose **Restart Database**.

<h3 id="postgres-pid-lock">Orphaned <code>postmaster.pid</code> File</h3>

**Symptom**: PostgreSQL log reports `lock file "postmaster.pid" already exists` and server does not start after a macOS crash or forced shutdown.

**Solution**:
Verify no postgres processes are active, then remove the stale lock file:
```bash
rm -f ~/Library/Application\ Support/GarageApp/pgdata/postmaster.pid
```

<h3 id="postgres-multithreaded">Multithreaded Startup Error</h3>

**Symptom**: Log contains `FATAL: postmaster became multithreaded during startup`.

**Cause**: Custom macOS locale settings can spawn auxiliary threads during runtime initialization before postgres fork safety validation.

**Solution**: Ensure `LC_ALL=C` is exported in the environment before launching postgres (handled automatically by `GarageApp`).

---

<h2 id="tcc-permissions">2. macOS Permissions (TCC) & Protected Files</h2>

<h3 id="authorization-denied"><code>authorization denied</code> on <code>chat.db</code> or <code>~/Library/Mail</code></h3>

**Symptom**: Ingestion log reports permission failure reading SMS / iMessage or Apple Mail databases.

```
sqlite3: unable to open database ~/Library/Messages/chat.db: authorization denied
```

**Solution**:
1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click the lock/add icon and ensure both **GarageApp** and your terminal emulator (e.g. **Terminal**, **iTerm2**, or **Ghostty**) are added with toggle enabled.
3. If permissions were changed while the app was running, quit and re-launch `GarageApp`.

---

<h2 id="embedding-issues">3. Embedding Models & Providers</h2>

<h3 id="provider-connection-refused">Ollama / LM Studio Connection Refused</h3>

**Symptom**: `garage backfill` fails with `ConnectionRefusedError: [Errno 61] Connection refused`.

**Solution**:
- **Ollama**: Verify Ollama is running (`ollama list`). Start Ollama via `ollama serve` or open the Ollama desktop app.
- **LM Studio**: Open LM Studio, select the **Developer** tab, and click **Start Server** on port `1234`.

<h3 id="vector-dimensions">Vector Dimension Mismatch</h3>

**Symptom**: PostgreSQL error `different vector dimensions` during backfill.

**Cause**: Each embedding table `emb_<slug>` is strictly typed to its model's vector dimensions (e.g., 1024 for `bge-m3`, 768 for `nomic-embed-text`).

**Solution**:
Inspect your registered model settings:
```bash
garage list-models
```
If registered incorrectly, drop the model (this discards its vectors) and re-register it with the right width, then backfill:
```bash
garage drop-model <model-name> --yes
garage register-model <model-name> --provider ollama --dims <correct-dims>
garage backfill --model <model-name>
```

---

<h2 id="mcp-issues">4. Model Context Protocol (MCP)</h2>

<h3 id="mcp-dns-rebinding">HTTP 421 Misdirected Request</h3>

**Symptom**: Browser or custom client receives `421 Misdirected Request` when connecting to `http://127.0.0.1:8787/mcp`.

**Cause**: On a loopback bind the MCP HTTP server checks the `Host` header (DNS rebinding protection). Requests must send `127.0.0.1:8787` or `localhost:8787`.

**Solution**:
Ensure your client sends `Host: 127.0.0.1:8787`. If accessing from a web application, specify `--allow-origin <origin>`. When serving remotely (`--allow-remote`), pass each name clients will use with `--allow-host <host:port>` (or `<host>:*`); with no `--allow-host` the `Host` check is switched off and a warning is logged.

<h3 id="claude-desktop-not-detecting">Claude Desktop Not Detecting Tools</h3>

**Symptom**: Claude Desktop starts, but the `rag_search` or `rag_get_document` tools are missing.

**Solution**:
1. Check `~/Library/Application Support/Claude/claude_desktop_config.json`.
2. Confirm the entry for `garage` exists and has the correct path to `garage-mcp`.
3. Re-install using:
   ```bash
   garage mcp-install --target claude-desktop
   ```
4. Completely quit Claude Desktop (Cmd+Q) and reopen it.

---

<h2 id="cloud-placeholders">5. Cloud Placeholders & Online Files</h2>

<h3 id="dropbox-icloud-mass-downloads">Unintended Downloads of Online-Only Files</h3>

**Symptom**: Ingestion takes a long time and starts downloading large quantities of cloud files from Dropbox or iCloud Drive.

**Solution**:
Garage meters cloud stub materialization. In `~/.garage.json`, adjust placeholder materialization settings:
```json
{
  "placeholders": {
    "materialize": false,
    "limit": 50,
    "max_bytes": 104857600
  }
}
```
Setting `"materialize": false` ensures online-only placeholders are indexed as metadata stubs without downloading their contents.

---

<h2 id="inspecting-logs">6. Inspecting Diagnostic Logs</h2>

When diagnosing issues, check the relevant logs:

- **PostgreSQL Database Logs**:
  `~/Library/Application Support/GarageApp/logs/postgres.log`
- **Ingestion & CLI Logs**:
  `~/Library/Application Support/GarageApp/logs/ingest.log`
- **MCP Server Logs**:
  `~/Library/Application Support/GarageApp/logs/mcp.log`

<div class="callout callout-info">
  <div class="callout-title">Need to Submit Logs for Support?</div>
  <p>Read our <a href="{{ '/contact.html' | relative_url }}">Contact & Log Sanitization Guide</a> to ensure your personal notes or confidential documents are removed before sharing log snippets.</p>
</div>
