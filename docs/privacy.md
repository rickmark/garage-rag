---
layout: default
title: Privacy and macOS Permissions
description: Multi-tier egress guards and macOS TCC security model.
---

# Privacy and macOS permissions

## The guarantee

Content classified `corpus_class = 'communication'` never reaches a cloud API.

This is enforced structurally, at four independent levels. Removing any one of
them fails the test suite.

### Level 1 — single chokepoint

`enrich/egress.py` is the only module that imports `anthropic` or constructs a
client. `../garage_python/tests/test_egress_block.py` parses every source file's AST and asserts
this, so a second client cannot appear unnoticed — including via a function-local
import.

### Level 2 — the type refuses to represent a forbidden send

`EgressRequest` *requires* a `corpus_class`, and validates it on construction:

```python
def __post_init__(self) -> None:
    if self.corpus_class is CorpusClass.COMMUNICATION:
        raise EgressBlocked(...)
    if not self.source_allows_cloud:
        raise EgressBlocked(...)
```

There is no way to build a request without declaring what kind of content it
carries, and no way to declare it a conversation and still send it. The class
check runs **first**, so a mistake elsewhere fails closed.

### Level 3 — per-source opt-in

`sources.allow_cloud_enrichment` defaults to `false` in the schema. The CLI
refuses to set it on a communication source at all:

```
$ garage add-source sms ~/Library/Messages --class communication --allow-cloud-enrichment
Error: communication sources may never enable cloud enrichment
```

### Level 4 — global switch

`cloud.enable_ocr` in `~/.garage.json` gates the entire path. Default `false`, in which case OCR is
Tesseract-only and fully offline. It additionally requires `cloud.api_key_file`
to name a readable key file, so forgetting the key fails closed rather than
erroring mid-run.

## What can leave, when enabled

To a **cloud API**: only image bytes, only for OCR, only from sources explicitly
opted in, and only when Tesseract's confidence falls below
`extraction.ocr_min_confidence`. Document text, code, and communications are
never sent to a cloud API. The only cloud client in the codebase is Anthropic's,
constructed in `enrich/egress.py`.

## Local inference endpoints

Two features post document text over HTTP to a **configured local server**,
which is assumed to be this machine:

- **Embeddings** — chunk text goes to `ollama_host` (default
  `http://localhost:11434`), `lmstudio_host` (default `http://localhost:1234/v1`)
  or `llama_host` (default `http://127.0.0.1:8790`, the llama.cpp API served by
  the app's own `LlamaXPCService`), depending on the registered model's provider.
- **Facts** (`garage enrich-facts`, LangExtract) — document text goes to
  `ollama_host`, or to `llama_host` with `--provider llama_xpc`. The LangExtract
  provider is **pinned to Ollama** by an explicit
  `ModelConfig(provider="OllamaLanguageModel")`; without that pin LangExtract
  chooses its backend by regex on the model name, and a `gemini-*` or `gpt-*`
  model id would have been sent to Google or OpenAI with an API key from the
  environment. `test_egress_block.py` asserts the pin structurally.

- **Answers** (`rag_ask` / `rag_generate` MCP tools, `garage ask`) — retrieved
  excerpts and the question go to the model named by `facts.model` on
  `facts.provider`: `llama_host` for `llama_xpc` (the default) or `ollama_host`
  for `ollama`. Both are local inference servers; there is no cloud generation
  path. Retrieved **communications can appear in that prompt**, exactly as they
  are embedded locally, and never leave the machine: `llama_host` is loopback by
  construction, and if `ollama_host` has been pointed off-box `rag_ask` runs
  every retrieved chunk's class through `assert_egress_allowed` before building
  the prompt, so a communication in the results aborts the call.

These hosts are not egress-guarded the way the cloud path is, because they are
loopback by default and the guard would otherwise block local inference on your
own messages. If you point `ollama_host` at another machine, fact extraction
runs each document's class through `assert_egress_allowed` first, so
communications are still never posted off-box. Embeddings are held to the same
rule: when the model's provider is not on this machine (`ollama_host` or
`lmstudio_host` pointed elsewhere), backfill, in-process or through the embed
worker, leaves chunks of communication documents out. They stay unembedded for
that model, and the backfill summary counts them as withheld. `llama_host` is different: it exists only for on-device
inference, so `LlamaXPCClient` refuses to construct at all unless the host is
loopback (`127.0.0.1`, `localhost` or `::1`) and never routes through an HTTP
proxy, whatever `http_proxy` says.

## macOS permissions (TCC)

Messages and Mail are protected by Transparency, Consent, and Control. Without
Full Disk Access:

```
$ sqlite3 ~/Library/Messages/chat.db .tables
Error: unable to open database: authorization denied

$ ls ~/Library/Mail
ls: Operation not permitted
```

The file *metadata* is visible, so a naive walker sees plausible files and fails
confusingly on every one. The pipeline detects this and reports it as a
permissions problem rather than a parse failure.

To grant: **System Settings → Privacy & Security → Full Disk Access**, and add
your terminal (or whichever process runs `garage`). Then re-run — idempotency
means nothing already indexed is re-done.

If you would rather not grant blanket access, copy `chat.db` (plus `-wal` and
`-shm`) to a working directory via Finder and register that copy as the source.
Narrower grant, more friction per refresh.

## Cloud placeholders and network traffic

`~/Dropbox` here is ~99% online-only stubs. **Reading a stub asks Dropbox to
download it** — a naive walk would have quietly pulled ~230 GB.

`placeholders.materialize` controls this, and even when enabled, downloads are
capped per run by `placeholders.limit` and `placeholders.max_bytes`. Every run reports what it fetched and what it
deferred; nothing is silently truncated.

## Serving over HTTP

The MCP server has **no authentication**. Over stdio that is fine: the client
spawns it as a child process and nothing else can reach it. Over HTTP it is the
whole security model, so three defences apply.

**Loopback by default.** `mcp.host` is `127.0.0.1`. Binding anything else requires
`--allow-remote`, and the refusal explains why rather than just erroring:

```
$ garage mcp-serve --http --host 0.0.0.0
refusing to bind 0.0.0.0: this server has no authentication and exposes your
entire corpus, including anything indexed from private communications.
```

**DNS-rebinding protection, always on.** Without it, a page you visit could
resolve its own hostname to `127.0.0.1` and POST to your loopback server from
your browser — reading your corpus without ever touching the network perimeter.
The `Host` allowlist blocks it:

```
$ curl -H 'Host: evil.example.com' http://127.0.0.1:8787/mcp   # 421
$ curl -H 'Host: 127.0.0.1:8787'   http://127.0.0.1:8787/mcp   # 200
```

Browser clients additionally need their origin allowed explicitly, with
`--allow-origin https://example.com`.

**No transport-level encryption.** Plain HTTP. Fine over loopback; if you expose
it, terminate TLS and authenticate at a reverse proxy. Do not put this on a
network you do not control.

## What is stored, and where

Everything stays in your local Postgres `rag` database: extracted text in
`documents.content`, chunk text in `chunks.text`, vectors in `emb_*`. No content
leaves the machine except as described above.

The database is unencrypted at rest, as Postgres normally is. If you index
private communications, the database file is as sensitive as the messages
themselves — consider FileVault (on by default on recent macOS) and treat
`pg_dump` output accordingly.
