-- Facts: atomic, self-contained claims distilled out of a document's text.
--
-- One document fans out into many facts, the same shape as chunks -- ordered
-- rows scoped to a document, replaced wholesale when the document is
-- re-extracted. `char_start`/`char_end` ground a fact back to the exact span
-- of `documents.content` it came from (when the extractor can locate it);
-- an ungrounded fact is dropped by the extractor rather than stored, since it
-- cannot be verified against the source.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS facts (
    id              bigserial   PRIMARY KEY,
    document_id     bigint      NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    ord             int         NOT NULL,
    fact            text        NOT NULL,
    -- The extractor's label for what kind of thing this is (its prompt's
    -- extraction_class, e.g. 'fact'). Not constrained: the prompt is generic
    -- and callers may specialize it per corpus.
    fact_class      text        NOT NULL DEFAULT 'fact',
    attributes      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    char_start      int,
    char_end        int,
    extractor       text        NOT NULL DEFAULT 'langextract',
    extractor_model text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    -- Keyword half of hybrid search over facts, maintained by Postgres itself.
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', fact)) STORED,
    CONSTRAINT facts_ord_unique UNIQUE (document_id, ord)
);

CREATE INDEX IF NOT EXISTS facts_tsv_gin ON facts USING gin (tsv);
CREATE INDEX IF NOT EXISTS facts_document ON facts (document_id);
