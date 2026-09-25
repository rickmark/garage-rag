"""Ingesting a Messages database: one document per conversation, one chunk per message.

A ``sqlite`` source is not walked file by file. Every Messages ``chat.db`` under
its root is read with :mod:`garage_rag.extract.messages`, and each conversation
is stored like any other document through the same
:class:`~garage_rag.ingest.gateway.IngestStorageGateway`, so the in-process
pipeline and the ingest XPC worker behave alike.

The document's text is the whole thread, one message per paragraph::

    [2026-09-24 18:02 UTC] Me: running late
    [2026-09-24 18:03 UTC] +15551234567: no worries

and each message is its own chunk, spanning exactly its paragraph, so a search
hit is one message with its sender and time rather than a window that starts
mid-thread. Times are UTC so the text, and with it the content hash, does not
change with the machine's time zone.

Conversations are always ``communication``, which keeps them on this machine
(see ``docs/privacy.md``). The per-document chunk cap does not apply: it guards
against a runaway file, and cutting a thread short would silently drop its
newest messages. The machine-output gate does not apply either, since every
line of a thread starts with a timestamp by construction.
"""

from __future__ import annotations

import logging
import sqlite3
from collections.abc import Callable
from pathlib import Path

from garage_rag.attribute.resolver import SelfIdentity
from garage_rag.db.models import CorpusClass
from garage_rag.extract.base import ContentKind, sha256_text
from garage_rag.extract.messages import (
    EXTRACTOR_NAME,
    EXTRACTOR_VERSION,
    ChatMessage,
    Conversation,
    find_databases,
    is_messages_database,
    read_conversations,
)
from garage_rag.ingest.chunking import TextChunk
from garage_rag.ingest.gateway import AuthorPayload, ChunkPayload, IngestStorageGateway, SourceContext

log = logging.getLogger(__name__)

CHUNKER = "message"
SIGNATURE = f"{ContentKind.CONVERSATION}:{CHUNKER}"
SELF_LABEL = "Me"


def conversation_uri(db_path: Path, conversation: Conversation) -> str:
    """Stable per thread: the database's path plus the chat's GUID."""
    return f"{db_path}#{conversation.guid}"


def _sender_label(message: ChatMessage) -> str:
    if message.is_from_me:
        return SELF_LABEL
    return message.sender or "Unknown"


def render(conversation: Conversation) -> tuple[str, list[TextChunk]]:
    """The document text and its chunks, one per message, with exact character spans."""
    parts: list[str] = []
    chunks: list[TextChunk] = []
    offset = 0
    for ordinal, message in enumerate(conversation.messages):
        stamp = message.sent_at.strftime("%Y-%m-%d %H:%M UTC")
        paragraph = f"[{stamp}] {_sender_label(message)}: {message.text}"
        if parts:
            offset += 2  # the blank line between messages
        chunks.append(
            TextChunk(
                ord=ordinal,
                text=paragraph,
                chunker=CHUNKER,
                heading_path=conversation.title,
                char_start=offset,
                char_end=offset + len(paragraph),
            )
        )
        parts.append(paragraph)
        offset += len(paragraph)
    return "\n\n".join(parts), chunks


def _identity_kind(handle: str) -> str:
    return "email" if "@" in handle else "phone"


def conversation_authors(conversation: Conversation, self_identity: SelfIdentity) -> list[AuthorPayload]:
    """Everyone who wrote in the thread: each other participant, then the owner if they wrote."""
    authors: list[AuthorPayload] = []
    for handle in conversation.participants:
        if self_identity.matches(email=handle):
            continue
        authors.append(
            AuthorPayload(
                name=handle,
                role="sender",
                confidence=1.0,
                evidence="imessage-handle",
                identities={_identity_kind(handle): handle},
            )
        )
    if self_identity.name and any(message.is_from_me for message in conversation.messages):
        authors.append(
            AuthorPayload(
                name=self_identity.name,
                role="sender",
                confidence=1.0,
                evidence="imessage-is-from-me",
                is_self=True,
            )
        )
    return authors


def ingest_conversation(
    gateway: IngestStorageGateway,
    source_ctx: SourceContext,
    db_path: Path,
    conversation: Conversation,
    *,
    self_identity: SelfIdentity,
    force: bool = False,
) -> int | None:
    """Store one conversation. Returns the chunks written, or None when it was unchanged."""
    uri = conversation_uri(db_path, conversation)
    text, chunks = render(conversation)
    content_hash = sha256_text(text).hex()

    existing = gateway.check_stat(source_ctx.slug, uri)
    if (
        existing.exists
        and not force
        and existing.content_sha256 == content_hash
        and existing.chunker == SIGNATURE
        and existing.state.upper() == "OK"
    ):
        gateway.record_seen(source_ctx.run_id, source_ctx.slug, uri)
        return None

    last = conversation.last_message_at
    meta = {
        "chat_guid": conversation.guid,
        "chat_identifier": conversation.chat_identifier,
        "service": conversation.service,
        "participants": conversation.participants,
        "is_group": conversation.is_group,
        "message_count": len(conversation.messages),
        "first_message_at": conversation.messages[0].sent_at.isoformat(),
        "last_message_at": last.isoformat() if last else None,
        "database": str(db_path),
    }
    return gateway.replace_document(
        run_id=source_ctx.run_id,
        source_slug=source_ctx.slug,
        uri=uri,
        title=conversation.title,
        lang=None,
        byte_size=len(text.encode("utf-8")),
        mtime=last.timestamp() if last else 0.0,
        source_sha256=None,
        content_sha256=content_hash,
        extractor=EXTRACTOR_NAME,
        extractor_version=EXTRACTOR_VERSION,
        chunker=SIGNATURE,
        content=text,
        meta=meta,
        corpus_class=CorpusClass.COMMUNICATION.value,
        trust_tier=source_ctx.default_trust.value,
        authors=conversation_authors(conversation, self_identity),
        chunks=[
            ChunkPayload(
                ord=chunk.ord,
                text=chunk.text,
                token_count=chunk.token_estimate,
                char_start=chunk.char_start,
                char_end=chunk.char_end,
                heading_path=chunk.heading_path,
                chunk_sha256=chunk.sha256.hex(),
                chunker=chunk.chunker,
            )
            for chunk in chunks
        ],
    )


def ingest_messages_source(
    gateway: IngestStorageGateway,
    source_ctx: SourceContext,
    counters,
    *,
    self_identity: SelfIdentity,
    force: bool = False,
    limit: int | None = None,
    is_cancelled: Callable[[], bool] | None = None,
    on_item: Callable[[str], None] | None = None,
) -> bool:
    """Ingest every conversation in every Messages database under the source's root.

    ``counters`` is the pipeline's ``IngestCounters``. Returns True when every
    database was read to the end, which is what lets reconcile retire the
    conversations that are gone; a cancellation, a ``limit`` or a database that
    could not be read returns False so nothing is retired on partial evidence.
    """
    root = Path(source_ctx.root)
    if not root.exists():
        counters.note_error(f"{root}: path does not exist")
        return False

    complete = True
    for db_path in find_databases(root):
        if not is_messages_database(db_path):
            log.info("Skipping %s: not a Messages database", db_path)
            continue
        log.info("Reading conversations from %s", db_path)
        try:
            for conversation in read_conversations(db_path):
                if is_cancelled is not None and is_cancelled():
                    log.info("Ingest cancelled by user for source %s", source_ctx.slug)
                    return False
                counters.seen += 1
                try:
                    written = ingest_conversation(
                        gateway, source_ctx, db_path, conversation, self_identity=self_identity, force=force
                    )
                except Exception as exc:  # noqa: BLE001 - one thread must not end the run
                    counters.note_error(f"{conversation.title}: {exc}")
                    log.warning("Ingest failed for conversation %s: %s", conversation.guid, exc, exc_info=True)
                    try:
                        gateway.record_seen(source_ctx.run_id, source_ctx.slug, conversation_uri(db_path, conversation))
                    except Exception as seen_exc:  # noqa: BLE001
                        log.warning("Could not record %s as seen: %s", conversation.guid, seen_exc)
                else:
                    if written is None:
                        counters.skipped += 1
                    else:
                        counters.indexed += 1
                        counters.chunks_written += written
                if on_item is not None:
                    on_item(conversation.title)
                if limit is not None and counters.seen >= limit:
                    log.info("Hit candidate limit (%d) for source %r", limit, source_ctx.slug)
                    return False
        except sqlite3.Error as exc:
            counters.note_error(f"{db_path.name}: {exc}")
            log.warning("Could not read %s: %s", db_path, exc)
            complete = False
    return complete


__all__ = [
    "SIGNATURE",
    "conversation_authors",
    "conversation_uri",
    "ingest_conversation",
    "ingest_messages_source",
    "render",
]
