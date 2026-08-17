-- Embedding model registry.
--
-- One table per model is not a workaround, it is the design: vector(1024) and
-- vector(2560) cannot share a column, and a single table with per-model nullable
-- columns would make HNSW indexes and backfills painful. Separate tables keyed
-- on a shared chunks row mean registering a model is a pure backfill that never
-- touches existing vectors.
--
-- The per-model tables themselves are created at runtime by
-- garage_rag.db.emb_tables, which derives storage type and index kind from the
-- model's dimensionality (see storage_kind / index_kind below).
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS embedding_models (
    id           smallserial PRIMARY KEY,
    slug         text        NOT NULL UNIQUE,
    provider     text        NOT NULL DEFAULT 'ollama',
    model_ref    text        NOT NULL,
    -- Native output width of the model.
    dims         int         NOT NULL,
    -- Width actually stored, after any Matryoshka truncation.
    stored_dims  int         NOT NULL,
    storage_kind text        NOT NULL,
    index_kind   text        NOT NULL,
    normalized   boolean     NOT NULL DEFAULT true,
    table_name   text        NOT NULL UNIQUE,
    is_default   boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT embedding_models_storage_check
        CHECK (storage_kind IN ('vector', 'halfvec')),
    CONSTRAINT embedding_models_index_check
        CHECK (index_kind IN ('hnsw', 'hnsw_bq', 'none')),
    CONSTRAINT embedding_models_dims_positive
        CHECK (dims > 0 AND stored_dims > 0 AND stored_dims <= dims),

    -- pgvector HNSW ceilings, enforced in the schema so an unindexable model
    -- cannot be registered as indexed: vector <= 2000, halfvec <= 4000.
    CONSTRAINT embedding_models_hnsw_ceiling CHECK (
        index_kind <> 'hnsw'
        OR (storage_kind = 'vector'  AND stored_dims <= 2000)
        OR (storage_kind = 'halfvec' AND stored_dims <= 4000)
    ),
    -- Identifier safety: table_name is interpolated into DDL and search SQL, so
    -- constrain it at the schema level rather than trusting callers.
    CONSTRAINT embedding_models_table_name_shape
        CHECK (table_name ~ '^emb_[a-z0-9_]+$')
);

-- At most one default model.
CREATE UNIQUE INDEX IF NOT EXISTS embedding_models_one_default
    ON embedding_models ((is_default)) WHERE is_default;
