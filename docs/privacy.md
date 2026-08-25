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

Only image bytes, only for OCR, only from sources explicitly opted in, and only
when Tesseract's confidence falls below `extraction.ocr_min_confidence`. Document
text, code, and communications are never sent.

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
