-- Link chunks to the facts they were derived from, so a fact can be
-- embedded exactly like any other chunk.
--
-- Giving a fact a row in `chunks` (chunker = 'facts:...') is all that is
-- needed to get it embedded: `embed.ollama.backfill_model` finds every chunk
-- missing a vector for a given model via a plain anti-join against `chunks`,
-- with no notion of where a chunk came from. `fact_id` is what marks a chunk
-- as fact-derived rather than extracted straight from `documents.content`,
-- and cascades so deleting a fact (e.g. on re-extraction) drops its chunk and,
-- transitively, its vectors in every per-model embedding table.
--
-- Idempotent: safe to re-run.

ALTER TABLE chunks ADD COLUMN IF NOT EXISTS fact_id bigint REFERENCES facts(id) ON DELETE CASCADE;

-- At most one chunk per fact.
CREATE UNIQUE INDEX IF NOT EXISTS chunks_fact_unique ON chunks (fact_id) WHERE fact_id IS NOT NULL;
