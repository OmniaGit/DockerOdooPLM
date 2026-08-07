#!/bin/bash
#
# Wipe the OdooPLM instance and recreate it from scratch.
#
# Stops the stack, deletes the database and the filestore volumes, pulls the
# images again and starts everything back up. The entrypoint then finds no
# database and rebuilds it, so the instance comes back exactly as a first boot:
# the demo product, the demo users, nothing a visitor left behind.
#
# Meant to be run unattended by scripts/../deploy/odooplm-reset.timer, and by
# hand through `make reset`.
#
# Configuration (environment):
#   RESET_PULL     1 to pull the images before starting again   (default 1)
#   RESET_PRUNE    1 to drop dangling images afterwards         (default 1)
#   RESET_TIMEOUT  seconds to wait for Odoo to report healthy   (default 1800)
#   RESET_EXPECT_MODULES  comma separated modules that must be installed once
#                  the instance is back, or the reset counts as failed
#                  (default plm; a demo server wants plm,plm_demo)
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${RESET_PULL:=1}"
: "${RESET_PRUNE:=1}"
: "${RESET_TIMEOUT:=1800}"
: "${RESET_EXPECT_MODULES:=plm}"

SCRIPT_NAME=reset-demo
# shellcheck source=scripts/lib-instance.sh
. ./scripts/lib-instance.sh

command -v docker >/dev/null || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"

[ -f compose.yaml ] || die "compose.yaml not found in $PWD"

# Before deleting anything: if compose cannot read the project, the reset would
# tear the instance down and then fail to bring it back.
check_compose_config

log "resetting the instance in $PWD"

# --volumes deletes odoo-data (filestore) and db-data (PostgreSQL) — that is the
# whole point of this script. Anything mounted from the host (config/odoo.conf,
# addons-extra/) is a bind mount and survives. Nothing outside this compose
# project is touched, so a reverse proxy running elsewhere keeps going.
log "stopping the stack and deleting its volumes"
docker compose down --volumes --remove-orphans

if [ "$RESET_PULL" = "1" ]; then
    # Not fatal: the volumes are already gone at this point, so a registry
    # hiccup must not leave the instance down until the next Sunday. Starting
    # again from the image already on disk is the better failure.
    log "pulling the images"
    docker compose pull --quiet \
        || log "WARNING: pull failed, starting from the images already on disk"
fi

log "starting the stack"
docker compose up -d

wait_healthy "$RESET_TIMEOUT"
verify_modules "$RESET_EXPECT_MODULES"

if [ "$RESET_PRUNE" = "1" ]; then
    # Dangling images only: the layers left behind by the images just pulled.
    log "removing dangling images"
    docker image prune -f >/dev/null
fi

log "done"
