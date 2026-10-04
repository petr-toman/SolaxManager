.DEFAULT_GOAL := help

COMPOSE_BASE := docker compose -f docker-compose.yml
COMPOSE_DEV  := docker compose -f docker-compose.yml -f docker-compose.dev.yml
COMPOSE_PROD := docker compose -f docker-compose.yml -f docker-compose.prod.yml

MODE ?= dev

.PHONY: help dev prod down rebuild-dev rebuild-prod ps db initialize

help:
	@printf '%s\n' 'Použití: make <příkaz>'
	@printf '%s\n' ''
	@printf '%s\n' 'Dostupné příkazy:'
	@printf '%s\n' '  dev             Spustí development stack'
	@printf '%s\n' '  prod            Spustí production stack'
	@printf '%s\n' '  down            Zastaví celý SolaxManager stack'
	@printf '%s\n' '  rebuild-dev     Čistě přebuildí a spustí development stack'
	@printf '%s\n' '  rebuild-prod    Čistě přebuildí a spustí production stack'
	@printf '%s\n' '  ps              Zobrazí stav služeb'
	@printf '%s\n' '  db              Otevře psql shell v PostgreSQL'
	@printf '%s\n' '  initialize      DESTRUKTIVNÍ reset persistentních dat; spustí MODE=dev (nebo MODE=prod)'

dev:
	$(COMPOSE_DEV) up -d --build

prod:
	$(COMPOSE_PROD) up -d --build

down:
	$(COMPOSE_BASE) down --remove-orphans

rebuild-dev:
	$(COMPOSE_DEV) down --remove-orphans
	$(COMPOSE_DEV) build --no-cache
	$(COMPOSE_DEV) up -d

rebuild-prod:
	$(COMPOSE_PROD) down --remove-orphans
	$(COMPOSE_PROD) build --no-cache
	$(COMPOSE_PROD) up -d

ps:
	$(COMPOSE_BASE) ps

db:
	$(COMPOSE_BASE) exec datastore sh -lc 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

initialize:
	@case "$(MODE)" in dev|prod) ;; *) printf 'MODE musí být dev nebo prod (zadáno: %s)\n' "$(MODE)"; exit 2 ;; esac
	@echo "WARNING: this removes PostgreSQL data and all persistent SolaxManager volumes."
	@printf "Continue? [y/N] "; read ans; [ "$$ans" = "y" ]
	$(COMPOSE_BASE) down -v --remove-orphans
	$(MAKE) --no-print-directory $(MODE)

%:
	@printf 'Neznámý příkaz: make %s\n\n' "$@"
	@$(MAKE) --no-print-directory help
	@exit 2
