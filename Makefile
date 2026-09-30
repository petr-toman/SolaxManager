.DEFAULT_GOAL := help

COMPOSE_BASE := docker compose -f docker-compose.yml
COMPOSE_DEV  := docker compose -f docker-compose.yml -f docker-compose.dev.yml
COMPOSE_PROD := docker compose -f docker-compose.yml -f docker-compose.prod.yml

.PHONY: help up dev prod down rebuild rebuild-dev rebuild-prod logs logs-solax logs-azrouter logs-forecast logs-reporter logs-api logs-controller ps db initialize

help:
	@printf '%s\n' 'Použití: make <příkaz>'
	@printf '%s\n' ''
	@printf '%s\n' 'Dostupné příkazy:'
	@printf '%s\n' '  up              Spustí základní stack'
	@printf '%s\n' '  dev             Spustí development stack'
	@printf '%s\n' '  prod            Spustí production stack'
	@printf '%s\n' '  down            Zastaví kontejnery a odstraní orphan kontejnery'
	@printf '%s\n' '  rebuild         Rebuild základního stacku bez cache'
	@printf '%s\n' '  rebuild-dev     Rebuild development stacku bez cache'
	@printf '%s\n' '  rebuild-prod    Rebuild production stacku bez cache'
	@printf '%s\n' '  logs            Sleduje logy všech služeb'
	@printf '%s\n' '  logs-solax      Sleduje log solax_reader'
	@printf '%s\n' '  logs-azrouter   Sleduje log azrouter_reader'
	@printf '%s\n' '  logs-forecast   Sleduje log solar_forecast_reader'
	@printf '%s\n' '  logs-reporter   Sleduje log reporteru'
	@printf '%s\n' '  logs-api        Sleduje log telemetry_api'
	@printf '%s\n' '  logs-controller Sleduje log controlleru'
	@printf '%s\n' '  ps              Zobrazí stav služeb'
	@printf '%s\n' '  db              Otevře psql shell v PostgreSQL'
	@printf '%s\n' '  initialize      DESTRUKTIVNÍ reset včetně PostgreSQL volume'

up:
	$(COMPOSE_BASE) up -d --build

dev:
	$(COMPOSE_DEV) up -d --build

prod:
	$(COMPOSE_PROD) up -d --build

down:
	$(COMPOSE_BASE) down --remove-orphans

rebuild:
	$(COMPOSE_BASE) down --remove-orphans
	$(COMPOSE_BASE) build --no-cache
	$(COMPOSE_BASE) up -d

rebuild-dev:
	$(COMPOSE_DEV) down --remove-orphans
	$(COMPOSE_DEV) build --no-cache
	$(COMPOSE_DEV) up -d

rebuild-prod:
	$(COMPOSE_PROD) down --remove-orphans
	$(COMPOSE_PROD) build --no-cache
	$(COMPOSE_PROD) up -d

logs:
	$(COMPOSE_BASE) logs -f --tail=100

logs-solax:
	$(COMPOSE_BASE) logs -f --tail=100 solax_reader

logs-azrouter:
	$(COMPOSE_BASE) logs -f --tail=100 azrouter_reader

logs-forecast:
	$(COMPOSE_BASE) logs -f --tail=100 solar_forecast_reader

logs-reporter:
	$(COMPOSE_BASE) logs -f --tail=100 reporter

logs-api:
	$(COMPOSE_BASE) logs -f --tail=100 telemetry_api

logs-controller:
	$(COMPOSE_BASE) logs -f --tail=100 controller

ps:
	$(COMPOSE_BASE) ps

db:
	$(COMPOSE_BASE) exec datastore sh -lc 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

initialize:
	@echo "WARNING: this removes PostgreSQL data and all persistent volumes."
	@printf "Continue? [y/N] "; read ans; [ "$$ans" = "y" ]
	$(COMPOSE_BASE) down -v --remove-orphans
	$(COMPOSE_BASE) build --no-cache
	$(COMPOSE_BASE) up -d

%:
	@printf 'Neznámý příkaz: make %s\n\n' "$@"
	@$(MAKE) --no-print-directory help
	@exit 2
