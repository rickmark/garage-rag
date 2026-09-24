-- Extensions and shared enum types.
-- Idempotent: safe to re-run.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Apache AGE (graph queries in openCypher). The app's bundled Postgres always ships it
-- (//ext/age); other servers (Homebrew, the CI pgvector image) usually don't, and nothing in
-- the schema depends on it yet, so it is created only where it is installed. It lives in its
-- own ag_catalog schema. The app's Postgres preloads it and puts ag_catalog last on search_path
-- (PostgresService); on other servers a session runs LOAD 'age' before calling ag_catalog.cypher().
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'age') THEN
        CREATE EXTENSION IF NOT EXISTS age;
    END IF;
END
$$;
