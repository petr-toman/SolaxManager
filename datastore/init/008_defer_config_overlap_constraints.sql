-- M1.4: make temporal overlap constraints deferred.
--
-- Config versioning closes the current [begdat,infinity) row and inserts the
-- replacement row in one atomic SQL statement. An immediate EXCLUDE
-- constraint checks the INSERT before the statement-level UPDATE is fully
-- visible to the constraint machinery and therefore reports a false overlap.
--
-- Deferring the exclusion check until transaction end preserves the desired
-- no-overlap guarantee while allowing the atomic close+insert operation.

ALTER TABLE solax_config
    DROP CONSTRAINT IF EXISTS solax_config_no_overlap;

ALTER TABLE solax_config
    ADD CONSTRAINT solax_config_no_overlap
    EXCLUDE USING gist (validity WITH &&)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE azrouter_config
    DROP CONSTRAINT IF EXISTS azrouter_config_no_overlap;

ALTER TABLE azrouter_config
    ADD CONSTRAINT azrouter_config_no_overlap
    EXCLUDE USING gist (
        scope WITH =,
        device_id WITH =,
        validity WITH &&
    )
    DEFERRABLE INITIALLY DEFERRED;
