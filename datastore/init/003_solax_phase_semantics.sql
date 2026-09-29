-- Correct SolaX phase-field semantics discovered during controlled CT/load tests.
-- Data[6..8] and Data[3..5] describe inverter AC phase output, not the actual
-- per-phase net grid flow. Preserve existing data by renaming the columns.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'grid_l1_power_w'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'inverter_l1_power_w'
    ) THEN
        ALTER TABLE solax_raw RENAME COLUMN grid_l1_power_w TO inverter_l1_power_w;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'grid_l2_power_w'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'inverter_l2_power_w'
    ) THEN
        ALTER TABLE solax_raw RENAME COLUMN grid_l2_power_w TO inverter_l2_power_w;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'grid_l3_power_w'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'inverter_l3_power_w'
    ) THEN
        ALTER TABLE solax_raw RENAME COLUMN grid_l3_power_w TO inverter_l3_power_w;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'grid_l1_current_a'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'inverter_l1_current_a'
    ) THEN
        ALTER TABLE solax_raw RENAME COLUMN grid_l1_current_a TO inverter_l1_current_a;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'grid_l2_current_a'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'inverter_l2_current_a'
    ) THEN
        ALTER TABLE solax_raw RENAME COLUMN grid_l2_current_a TO inverter_l2_current_a;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'grid_l3_current_a'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'solax_raw'
          AND column_name = 'inverter_l3_current_a'
    ) THEN
        ALTER TABLE solax_raw RENAME COLUMN grid_l3_current_a TO inverter_l3_current_a;
    END IF;
END $$;
