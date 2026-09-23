-- Scan results get their own columns instead of living in `sources.config`.
--
-- `config` is user-facing source configuration (include_code, ...); the last
-- scan's item type, per-kind breakdown and time are bookkeeping written by the
-- scanner, and `sync` rewriting config from garage.json should not erase them.
-- `expected_items` duplicated `expected_elements` (the one everything reads).
--
-- Idempotent: safe to re-run.

ALTER TABLE sources ADD COLUMN IF NOT EXISTS scan_item_type text;
ALTER TABLE sources ADD COLUMN IF NOT EXISTS scan_details   jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE sources ADD COLUMN IF NOT EXISTS scanned_at     timestamptz;

-- Carry over what earlier scans left in config, then drop it from there.
UPDATE sources
SET scan_item_type = coalesce(scan_item_type, config->>'item_type'),
    scan_details   = CASE WHEN jsonb_typeof(config->'scan_details') = 'object'
                          THEN config->'scan_details' ELSE scan_details END,
    scanned_at     = coalesce(
                         scanned_at,
                         CASE WHEN jsonb_typeof(config->'scanned_at') = 'number'
                              THEN to_timestamp((config->>'scanned_at')::double precision) END)
WHERE config ?| ARRAY['item_type', 'scan_details', 'scanned_at'];

UPDATE sources
SET config = config - 'expected_items' - 'item_type' - 'scan_details' - 'scanned_at'
WHERE config ?| ARRAY['expected_items', 'item_type', 'scan_details', 'scanned_at'];

ALTER TABLE sources DROP COLUMN IF EXISTS expected_items;
