-- The cloud OCR fallback is gone, and with it the per-source switch that let a
-- source opt into it. OCR is Tesseract only and nothing leaves the machine, so
-- `sources.allow_cloud_enrichment` has no reader left.
--
-- 003_core.sql no longer creates the column; this drops it from databases
-- created before that.
--
-- Idempotent: safe to re-run.

ALTER TABLE sources DROP COLUMN IF EXISTS allow_cloud_enrichment;
