-- M1.6: clear speculative Phase Unbalanced values.
--
-- ReadSetData[190] was tested on the target inverter and did not change when
-- Phase Unbalanced was toggled. Keep the schema columns reserved, but remove
-- the unsupported interpretation from existing history until the correct
-- local API index is identified empirically.

UPDATE solax_config
SET phase_unbalanced = NULL,
    phase_unbalanced_code = NULL
WHERE phase_unbalanced IS NOT NULL
   OR phase_unbalanced_code IS NOT NULL;
