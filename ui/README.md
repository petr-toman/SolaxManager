# ui

Web interface for SolaxManager.

UI is intentionally not a first-phase priority. The first implementation only proves that the service is independently deployable.

## Planned stages

### Stage 1 – current state
- current PV power
- house load
- grid import/export
- battery power and SOC
- boiler/AZ Router state
- controller mode
- freshness / last update

### Stage 2 – history
- power graphs
- 15-minute and daily energy statistics
- SolaX vs distributor comparison
- controller actions overlaid on battery/PV history

### Stage 3 – configuration
- controller mode
- rule enable/disable
- safe editable parameters
- rule/action audit log

## Architectural rule

The browser/UI must not communicate directly with SolaX or AZ Router. It consumes SolaxManager data/API only.
