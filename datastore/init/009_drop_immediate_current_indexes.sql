-- M1.5: remove immediate partial unique indexes for current config rows.
--
-- Deferred temporal EXCLUDE constraints already prevent overlapping validity
-- ranges, including two open-ended current rows. These partial unique indexes
-- were redundant and were checked immediately, which blocked the atomic
-- close-current + insert-successor statement.

DROP INDEX IF EXISTS idx_solax_config_current;
DROP INDEX IF EXISTS idx_azrouter_config_current;
