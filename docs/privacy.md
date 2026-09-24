---
layout: default
title: Privacy and macOS Permissions
description: One egress choke point, a destination allowlist, communications kept local, and the macOS TCC security model.
---

# Privacy and macOS permissions

## The guarantee

Garage sends content only to approved destinations: this machine, and the Ollama
or LM Studio server you configure. Communications never leave this machine.
There is no cloud AI client in the codebase.

This is enforced structurally, in layers that are each tested on their own
(`garage_python/tests/test_egress_block.py`). Removing any one of them fails the
test suite.

### Layer 1 — one choke point

`garage_rag/net/egress.py` is the only module that imports an outbound network
client library (`httpx`, `urllib.request`, `requests`, raw `socket`, ...) or a
library that opens its own connections (the `ollama` SDK). Every outbound client
is built there, after its destination is checked:

- `egress.http_client(purpose=..., base_url=...)` — an `httpx` client. Every
  model server (LM Studio, Ollama and the app's `LlamaXPCService`: embeddings,
  fact extraction, answers, LM Studio model management) is reached through
  Garage's own client, `garage_rag/inference`, whose transport is built here;
- `egress.url_opener(purpose=..., base_url=...)` — a stdlib client (the
  `mcp-test` probe).

The test parses every source file's AST, so a function-local or
`importlib.import_module` import is caught too. Inbound and local infrastructure
is exempt, and listed file by file rather than by pattern: the gRPC server and
its generated stubs, the MCP server's uvicorn, and psycopg's connection to
Postgres. The gRPC *client* of the app's facade is listed too, and checks its
address with the guard (loopback only).

### Layer 2 — no cloud AI SDK

No source file imports a cloud AI SDK (`anthropic`, `openai`, `google.genai`,
`google.cloud`, `cohere`, `mistralai`, `boto3`, upstream `langextract` and the
like), and `uv.lock` contains none. Neither the `openai` nor the `ollama`
package is a dependency: LM Studio's and Ollama's HTTP APIs are a few JSON
routes, made by `garage_rag/inference` with the guard's `httpx` client.

There used to be an optional Claude vision fallback for OCR. It has been removed:
OCR is Tesseract only, on this machine, and the `cloud` settings section and the
per-source `allow_cloud_enrichment` flag are retired (an older config that still
has them loads with a warning).

### Layer 3 — the destination allowlist

`egress.check_destination` runs before any client is built. It approves:

- **loopback** — `localhost` or a literal loopback address (`127.0.0.0/8`,
  `::1`): the app's own `LlamaXPCService` on `embedding.llama_host` (default
  `http://127.0.0.1:8790`, and required to be loopback), and Ollama or LM Studio
  running on this Mac;
- **the configured model servers** — exactly the origins (scheme, host and port)
  of `embedding.ollama_host` and `embedding.lmstudio_host`, which may be another
  machine.

Anything else raises `EgressBlocked`. There is no setting that adds other hosts.
A host *name* other than `localhost` is never treated as loopback, even if it
resolves to loopback today, because a DNS answer can change; it is approved only
when it is the configured server.

The clients the guard builds ignore the environment's proxy variables and never
follow a redirect, and each one refuses a request addressed to any origin but the
one it was built for, so neither `http_proxy` nor a server's `Location` header
can send content elsewhere.

### Layer 4 — communications stay on this machine

Content classified `corpus_class = 'communication'` never goes to a destination
that is not loopback, even an approved one. The guard checks this before
anything else when the caller says what it is sending:

- **Facts** (`garage enrich-facts`) pass each document's class, so a message is
  never posted to an off-box Ollama or LM Studio; the refusal comes before the document's
  stored facts are touched.
- **Answers** (`rag_ask`) run every retrieved excerpt's class through the guard
  before building a prompt for an off-box Ollama or LM Studio, so a communication in the
  results aborts the call.
- **Embeddings** — backfill, in-process or through the embed worker, asks
  `egress.allows_communications` and leaves chunks of communication documents
  out for a provider that is not on this machine. They stay unembedded for that
  model, and the backfill summary counts them as withheld
  (`test_embed_egress.py`).

### Layer 5 — local fact extraction

Only the local part of LangExtract is shipped, vendored as `enrich/langextract`.
Upstream chooses its backend by regex on the model name and would send a
`gemini-*` or `gpt-*` model id to Google or OpenAI; that routing and those
backends are not vendored, and `enrich/facts.py` refuses a cloud model id with a
clear error. Every extraction runs on `LocalLanguageModel`, Garage's own
provider, through the same loopback-only client.

### What these layers do not cover — MCP clients

The MCP server hands search results and document excerpts, communications
included, to whichever client is connected to it. When that client is Claude
Desktop or Claude Code, it sends what it receives to its own model provider
under its own terms. Garage does not, but connecting such a client is a decision
about where retrieved content goes; `rag_search` results carry each hit's
`corpus_class` so a client can tell communications apart.

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
leaves the machine except to the model servers you configure (communications
never do), or through an MCP client or `--allow-remote`, described above.

The database is unencrypted at rest, as Postgres normally is. If you index
private communications, the database file is as sensitive as the messages
themselves — consider FileVault (on by default on recent macOS) and treat
`pg_dump` output accordingly.
