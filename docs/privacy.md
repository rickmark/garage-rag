---
layout: default
title: Privacy and macOS Permissions
description: No cloud AI, loopback-only model servers, and the macOS TCC security model.
---

# Privacy and macOS permissions

## The guarantee

No document content leaves this machine. Garage contains no cloud AI client,
and every model server it talks to must be on loopback.

This is enforced structurally, in layers that are each tested on their own
(`garage_python/tests/test_egress_block.py`). Removing any one of them fails the
test suite.

### Layer 1 — no cloud AI SDK

No source file imports a cloud AI SDK: `anthropic`, `google.genai`,
`google.generativeai`, `google.cloud`, `cohere`, `mistralai`, `boto3` and the
like. The test parses every source file's AST, so a function-local or
`importlib.import_module` import is caught too, and it checks that `uv.lock`
contains none of them either. The vendored part of LangExtract (`enrich/langextract`)
is scanned like the rest; upstream `langextract` is on the list, because its
provider registry routes model ids to Google and OpenAI.

The `openai` SDK is the one exception, and only in `embed/lmstudio.py`: LM Studio
serves an OpenAI-compatible API, and the SDK is its client. It is constructed with
a loopback-checked `base_url` and an HTTP client that ignores proxy settings, so
it can only reach this machine.

There used to be an optional Claude vision fallback for OCR. It has been removed:
OCR is Tesseract only, on this machine, and the `cloud` settings section and the
per-source `allow_cloud_enrichment` flag are retired (an older config that still
has them loads with a warning).

### Layer 2 — model servers are loopback, by rule

Three features post document text over HTTP to a model server:

- **Embeddings** — chunk text goes to `embedding.ollama_host` (default
  `http://localhost:11434`), `embedding.lmstudio_host` (default
  `http://localhost:1234/v1`) or `embedding.llama_host` (default
  `http://127.0.0.1:8790`, the llama.cpp API served by the app's own
  `LlamaXPCService`), depending on the registered model's provider.
- **Facts** (`garage enrich-facts`) — document text goes to `ollama_host`, or to
  `llama_host` with `--provider llama_xpc`.
- **Answers** (`rag_ask` / `rag_generate` MCP tools, `garage ask`) — retrieved
  excerpts, communications included, and the question go to the model named by
  `facts.model` on `facts.provider`.

All three hosts must be loopback: `localhost` or a literal loopback address
(`127.0.0.0/8`, `::1`). Any other value is a configuration error, so a config
that points `ollama_host` at another machine does not load:

```
$ garage stats
Config error: /Users/me/.garage.json: 1 validation error for Settings
ollama_host
  Value error, embedding.ollama_host must be a loopback URL (localhost,
127.0.0.1 or ::1); got 'http://gpu-box:11434'. Document text is only ever sent
to model servers on this machine.
```

Every client checks the URL again when it is built, for hosts passed in directly
rather than through the configuration, and none of them follows the
environment's `http_proxy` or a server's redirect. A host *name* other than
`localhost` is refused even if it resolves to loopback today, because a DNS
answer can change. The same rule covers the app's gRPC facade, which carries
document text between the app's XPC workers and the Python service.

### Layer 3 — a short list of network clients

Only a listed set of modules may import an HTTP or socket client (`httpx`,
`ollama`, `openai`, `urllib.request`, `grpc`, ...), and each of them enforces
layer 2. A new one fails the test until it does too and is added to the list.

### Layer 4 — local fact extraction

Only the local part of LangExtract is shipped, vendored as `enrich/langextract`.
Upstream chooses its backend by regex on the model name and would send a
`gemini-*` or `gpt-*` model id to Google or OpenAI; that routing and those
backends are not vendored, and `enrich/facts.py` refuses a cloud model id with a
clear error. Every extraction runs on one of the two local providers.

### What these layers do not cover — MCP clients

The MCP server hands search results and document excerpts, communications
included, to whichever client is connected to it. When that client is Claude
Desktop or Claude Code, it sends what it receives to its own model provider
under its own terms. Garage does not, but connecting such a client is a decision
about where retrieved content goes; `rag_search` results carry each hit's
`corpus_class` so a client can tell communications apart.

### Behind the layers — communications and embedding

Content classified `corpus_class = 'communication'` has one more guard, from
before the loopback rule: backfill, in-process or through the embed worker,
leaves chunks of communication documents out when a model's provider is not on
this machine, and counts them as withheld. The loopback rule makes that
unreachable; it stays as a second line should the rule ever be loosened
(`test_embed_egress.py`).

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
leaves the machine; the one way to expose it is to serve MCP over HTTP on a
non-loopback address with `--allow-remote`, described above.

The database is unencrypted at rest, as Postgres normally is. If you index
private communications, the database file is as sensitive as the messages
themselves — consider FileVault (on by default on recent macOS) and treat
`pg_dump` output accordingly.
