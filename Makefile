ODOO_VERSION ?= 19.0
VARIANT      ?= full
IMAGE        ?= odooplm:$(ODOO_VERSION)$(if $(filter-out full,$(VARIANT)),-$(VARIANT),)
ODOOPLM_REF  ?= $(ODOO_VERSION)

COMPOSE ?= docker compose

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the image locally (VARIANT=full|slim)
	docker build \
		--build-arg ODOO_VERSION=$(ODOO_VERSION) \
		--build-arg ODOOPLM_REF=$(ODOOPLM_REF) \
		--build-arg VARIANT=$(VARIANT) \
		-t $(IMAGE) .

.PHONY: pull
pull: ## Pull the published images
	$(COMPOSE) pull

.PHONY: up
up: ## Start Odoo + PostgreSQL in the background
	$(COMPOSE) up -d

.PHONY: run
run: ## Start the stack in the foreground
	$(COMPOSE) up

.PHONY: down
down: ## Stop the stack (data is kept)
	$(COMPOSE) down --remove-orphans

.PHONY: destroy
destroy: ## Stop the stack and DELETE the database and filestore
	$(COMPOSE) down --remove-orphans --volumes

.PHONY: restart
restart: ## Restart the Odoo container
	$(COMPOSE) restart odoo

.PHONY: logs
logs: ## Follow the Odoo logs
	$(COMPOSE) logs -f odoo

.PHONY: shell
shell: ## Open a shell in the Odoo container
	$(COMPOSE) exec odoo bash

.PHONY: root-shell
root-shell: ## Open a root shell in the Odoo container
	$(COMPOSE) exec -u 0 odoo bash

.PHONY: odoo-shell
odoo-shell: ## Open the Odoo python shell on the PLM database
	$(COMPOSE) exec odoo odoo shell -d $${ODOOPLM_DB:-odooplm} --db_host db

.PHONY: psql
psql: ## Open psql on the PLM database
	$(COMPOSE) exec db psql -U $${POSTGRES_USER:-odoo} -d $${ODOOPLM_DB:-odooplm}

.PHONY: update
update: ## Update the installed PLM modules (MODULES=plm,plm_web_3d)
	$(COMPOSE) exec odoo odoo -d $${ODOOPLM_DB:-odooplm} --db_host db \
		-u $${MODULES:-plm} --stop-after-init
	$(COMPOSE) restart odoo

.PHONY: smoke-test
smoke-test: ## Boot the stack, check Odoo answers and plm is installed, tear it down
	./scripts/smoke-test.sh $(IMAGE)
