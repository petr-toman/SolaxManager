# controller

Hardware control and automation service.

This is the critical GO / NO-GO component for SolaxManager.

## Responsibility

The controller is the only SolaxManager component allowed to write device configuration.

It consists conceptually of two layers:

1. **Device control adapter** – typed GET/SET operations and explicit actions.
2. **Rule engine / scheduler** – decides when an action should be requested.

These layers remain separate so device protocol changes do not affect automation logic.

## M0.5A: read-only SolaX config adapter

The first M0.5 step intentionally implements **reads only**. It calls the local
SolaX HTTP endpoint with `optType=ReadSetData`, validates the returned settings
array, and exposes only indexes verified on the target inverter/firmware.

Verified mapping:

| Index | Meaning | Encoding / observed values |
|---:|---|---|
| 24 | inverter RTC minute/second | high byte = minute, low byte = second |
| 25 | inverter RTC day/hour | high byte = day, low byte = hour |
| 26 | inverter RTC year/month | high byte = 2-digit year, low byte = month |
| 27 | work mode | `0=self_use`, `2=backup_mode`; unknown values are not guessed |
| 28 | Self Use minimum SOC | percent |
| 29 | charge from grid | `0=disabled`, `1=enabled` |
| 30 | grid-charge target SOC | percent |
| 36 | forced charge start | high byte = minute, low byte = hour |
| 37 | forced charge end | high byte = minute, low byte = hour |
| 38 | allowed discharge start | high byte = minute, low byte = hour |
| 39 | allowed discharge end | high byte = minute, low byte = hour |
| 185 | HotStandby | observed `0=enabled`, `1=disabled` |

The unusual HotStandby polarity is deliberate: it reflects the values verified
on the target inverter rather than a generic boolean assumption.

### Commands

With the development stack running:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get min_soc
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get work_mode
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get charge_from_grid
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get hot_standby
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller get inverter_time
```

Read all verified configuration:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller config
```

or JSON:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller config --json
```

Diagnostic raw `ReadSetData` dump:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm controller raw
```

No command in M0.5A writes inverter configuration.

## Planned M0.5 write proof-of-concept

After the reads are verified against the real inverter, add controlled operations
such as:

```text
set min_soc <percent>
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

Default is **dry-run**. The development Compose overlay forces dry-run.

## Safety requirements

- input ranges must be validated before writing
- no raw register writes may leak into rule code
- actions should be idempotent where possible
- all write attempts must be auditable
- controller must be able to read back the resulting state
- automatic operation must include hysteresis/cooldown where relevant
- unknown enum values must be exposed as unknown rather than silently guessed

## Future rule configuration

Rules should eventually be configurable rather than hard-coded. Example concepts:

- seasonal Min SOC
- morning hot-water battery allowance
- low-SOC recovery charge
- periodic 100% charge when battery has not reached full SOC for a configurable period
- weather/production forecast adjustments
