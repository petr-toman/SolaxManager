-- M1.3: track SolaX Phase Unbalanced setting in versioned configuration.
--
-- On the target X3-Hybrid G4, local ReadSetData index 190 maps to the
-- three-phase unbalanced output setting:
--   0 = Disabled (balanced per-phase inverter output)
--   1 = Enabled  (per-phase output follows per-phase load)

ALTER TABLE solax_config
    ADD COLUMN IF NOT EXISTS phase_unbalanced BOOLEAN,
    ADD COLUMN IF NOT EXISTS phase_unbalanced_code INTEGER;
