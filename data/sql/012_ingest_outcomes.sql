-- Files that produced no document, remembered so the next run can skip them while
-- nothing about them changed: an image with no text is not OCR'd again, and a failed
-- extraction is retried only when the file's bytes or its extractor's version change.
--
--   outcome            -- 'no_text' | 'failed' (an extraction error, kept in `error`)
--   extractor_revision -- extractor and its VERSION when recorded, e.g. 'image:1'; a
--                         row from another revision is ignored, so the file is retried
--
-- A row goes when the file is indexed. Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS ingest_outcomes (
    source_id          bigint      NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    uri                text        NOT NULL,
    outcome            text        NOT NULL,
    byte_size          bigint,
    mtime              timestamptz,
    source_sha256      bytea,
    extractor_revision text        NOT NULL DEFAULT '',
    error              text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_id, uri),
    CONSTRAINT ingest_outcomes_outcome_check CHECK (outcome IN ('no_text', 'failed'))
);
