-- M1.3: track SolaX Phase Unbalanced setting in versioned configuration.
--
-- On the target X3-Hybrid G4, local ReadSetData index 190 maps to the
-- three-phase unbalanced output setting:
--   0 = Enabled  (per-phase output follows per-phase load)
--   1 = Disabled (balanced per-phase inverter output)
--
-- Note: this is the local ReadSetData representation observed on the target
-- inverter. It is intentionally not assumed to share the value polarity of
-- the public Modbus Phase Power Balance register.

ALTER TABLE solax_config
    ADD COLUMN IF NOT EXISTS phase_unbalanced BOOLEAN,
    ADD COLUMN IF NOT EXISTS phase_unbalanced_code INTEGER;
