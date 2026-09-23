-- The similarity metric each embedding model was trained for.
--
-- models.json declares it per model; registration copies it here because two
-- things must agree with it for a model's lifetime: the operator class its HNSW
-- index was built with (vector_cosine_ops, halfvec_l2_ops, vector_ip_ops, ...)
-- and the operator search orders by (<=>, <->, <#>). An index built for one
-- metric is not used by a query on another.
--
-- Every model registered before this column existed was indexed for cosine, so
-- that is the default.
--
-- Idempotent: safe to re-run.

ALTER TABLE embedding_models ADD COLUMN IF NOT EXISTS distance text NOT NULL DEFAULT 'cosine';

DO $$
BEGIN
    ALTER TABLE embedding_models
        ADD CONSTRAINT embedding_models_distance_check
        CHECK (distance IN ('cosine', 'l2', 'inner_product'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;
