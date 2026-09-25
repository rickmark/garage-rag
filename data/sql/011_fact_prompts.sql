-- Facts from more than one prompt.
--
-- `enrich-facts` runs every enabled prompt in `facts.prompts` (the built-in
-- `default` unless overridden), so a document's facts are now scoped to the
-- prompt that produced them: re-running one prompt replaces only its own
-- facts. `prompt_sha256` hashes what that prompt showed the model (its
-- description and examples); it is NULL on facts extracted before this
-- migration, all of which came from the one built-in prompt, `default`.
--
-- `fact_runs` records the last extraction of each (document, prompt), with the
-- prompt hash, the document's `content_sha256` and the model it ran with. A
-- run that found no facts still leaves a row, which is what lets
-- `enrich-facts --stale-only` skip a document none of whose inputs changed and
-- redo one whose prompt, content or model did.
--
-- Idempotent: safe to re-run.

ALTER TABLE facts ADD COLUMN IF NOT EXISTS prompt_name   text NOT NULL DEFAULT 'default';
ALTER TABLE facts ADD COLUMN IF NOT EXISTS prompt_sha256 bytea;

-- `ord` counts within one prompt's facts, not across the document.
ALTER TABLE facts DROP CONSTRAINT IF EXISTS facts_ord_unique;
DO $$ BEGIN
    ALTER TABLE facts ADD CONSTRAINT facts_prompt_ord_unique UNIQUE (document_id, prompt_name, ord);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS fact_runs (
    document_id     bigint      NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    prompt_name     text        NOT NULL,
    prompt_sha256   bytea       NOT NULL,
    content_sha256  bytea       NOT NULL,
    extractor_model text        NOT NULL,
    facts           int         NOT NULL DEFAULT 0,
    extracted_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, prompt_name)
);
