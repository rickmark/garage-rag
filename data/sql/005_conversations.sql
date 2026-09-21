-- Conversations and messages: structured storage for communication sources
-- (sms/imessage chat.db, mail) prior to synthesis into a document.
--
-- A conversation is one thread between the corpus owner and a single other
-- participant (`other_author_id`), scoped to the source it came from
-- (sources.slug 'sms', 'mail', ...). Its messages accumulate here as they are
-- ingested; a separate synthesis step concatenates them in `sent_at` order
-- into one synthetic `documents` row (`document_id`), which is then chunked
-- and embedded exactly like any other document. Re-synthesis after new
-- messages arrive replaces that document without touching the raw messages.
--
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Conversations: one thread with one other participant.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversations (
    id                bigserial   PRIMARY KEY,
    source_id         bigint      NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    other_author_id   bigint      NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
    -- The source's native thread identifier (chat.db chat GUID, a derived
    -- mail thread key, ...), so re-ingest finds the same conversation rather
    -- than duplicating it.
    external_id       text        NOT NULL,
    -- The synthetic document this conversation was last flattened into.
    -- Nullable until first synthesis; ON DELETE SET NULL because deleting the
    -- document (e.g. to force a rebuild) must not delete the raw messages.
    document_id       bigint      REFERENCES documents(id) ON DELETE SET NULL,
    first_message_at  timestamptz,
    last_message_at   timestamptz,
    message_count     int         NOT NULL DEFAULT 0,
    -- Set when `document_id` was last (re)built; null means never synthesized.
    synthesized_at    timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT conversations_external_id_unique UNIQUE (source_id, external_id),
    CONSTRAINT conversations_document_unique UNIQUE (document_id)
);

CREATE INDEX IF NOT EXISTS conversations_source        ON conversations (source_id);
CREATE INDEX IF NOT EXISTS conversations_other_author   ON conversations (other_author_id);

-- ---------------------------------------------------------------------------
-- Messages: individual events within a conversation, sender identified by
-- `author_id` (the owner or `conversations.other_author_id`).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
    id              bigserial   PRIMARY KEY,
    conversation_id bigint      NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    author_id       bigint      NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
    -- The source's native message identifier (chat.db ROWID/guid, mail
    -- Message-ID), for idempotent re-ingest. Null when a source has none.
    external_id     text,
    sent_at         timestamptz NOT NULL,
    body            text        NOT NULL,
    meta            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT messages_external_id_unique UNIQUE (conversation_id, external_id)
);

CREATE INDEX IF NOT EXISTS messages_conversation_sent ON messages (conversation_id, sent_at);
CREATE INDEX IF NOT EXISTS messages_author            ON messages (author_id);
