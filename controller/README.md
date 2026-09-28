# controller

Hardware control and automation service.

This is the critical GO / NO-GO component for SolaxManager.

## Responsibility

The controller is the only SolaxManager component allowed to write device configuration.

It consists conceptually of two layers:

1. **Device control adapter** – typed GET/SET operations and explicit actions.
2. **Rule engine / scheduler** – decides when an action should be requested.

These layers remain separate so device protocol changes do not affect automation logic.

## Initial M0.5 proof-of-concept

Before building advanced reporting and UI, verify that the current inverter and firmware permit reliable operations such as:

```text
get min_soc
set min_soc <percent>
get min_soc
get work_mode
force_charge <target_soc>
stop_force_charge
```

A write test must:

1. read the current value,
2. validate the requested value,
3. write it,
4. read it back,
5. verify the result,
6. restore the original value where appropriate,
7. log the complete action.

## Modes

- `off` – no evaluation and no writes
- `manual` – explicit user-requested actions only
- `dry-run` – rules are evaluated and actions logged but not executed
- `auto` – validated rules may perform hardware writes

Default is **dry-run**.

## Safety requirements

- input ranges must be validated before writing
- no raw register writes may leak into rule code
- actions should be idempotent where possible
- all write attempts must be auditable
- controller must be able to read back the resulting state
- automatic operation must include hysteresis/cooldown where relevant

## Future rule configuration

Rules should eventually be configurable rather than hard-coded. Example concepts:

- seasonal Min SOC
- morning hot-water battery allowance
- low-SOC recovery charge
- periodic 100% charge when battery has not reached full SOC for a configurable period
- weather/production forecast adjustments
