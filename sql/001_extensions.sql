-- Extensions and shared enum types.
-- Idempotent: safe to re-run.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- What a resource IS. The primary partition of the corpus.
--   document      -- prose: notes, papers, reports, presentations, spreadsheets
--   code          -- source code, whether yours or vendored
--   communication -- exchanged between people; never leaves this machine
--
-- Drives chunking strategy, search filtering, and the cloud-egress block.
DO $$ BEGIN
    CREATE TYPE corpus_class AS ENUM ('document', 'code', 'communication');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- How much a resource is TRUSTED, and whose it is. Orthogonal to corpus_class.
--   authored  -- written by the corpus owner (own notes, own commits, sent messages)
--   reference -- external material already QA'ed: downloaded papers, vendored
--                code, third-party documentation. High trust.
--   received  -- sent to the owner by someone else: inbound messages and mail,
--                documents others wrote. Trust depends on the author.
--
-- The pairing is what makes this expressive: ('code','reference') is a vendored
-- dependency, ('code','authored') is your own work, ('communication','received')
-- is someone else's message.
DO $$ BEGIN
    CREATE TYPE trust_tier AS ENUM ('authored', 'reference', 'received');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE author_role AS ENUM ('author', 'committer', 'sender', 'recipient', 'cc');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Outcome of the last ingest attempt for a document.
--   placeholder -- cloud stub, no local content; not a failure, just absent
DO $$ BEGIN
    CREATE TYPE ingest_state AS ENUM (
        'ok', 'extract_failed', 'embed_partial', 'placeholder'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
