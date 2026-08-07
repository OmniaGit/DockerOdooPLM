#!/bin/bash
#
# Apply configuration changes and bring the instance back.
#
#   ./scripts/restart.sh          (or: make restart)
#
# Run it after editing .env or config/odoo.conf. The two need different
# treatment, which is the whole reason this script exists:
#
#   config/odoo.conf  is a bind mount — the file inside the container is already
#                     the new one, Odoo just has to be restarted to read it.
#   .env              is read by docker compose when it *creates* a container.
#                     Ports, image, passwords: a plain `restart` keeps running
#                     the old values, and the change looks like it did nothing.
#
# So: `docker compose up -d` first, which recreates the container when .env
# changed and is a no-op when it did not — and only then, if nothing was
# recreated, an explicit restart for config/odoo.conf.
#
# The database and the filestore are never touched. To throw those away instead,
# use scripts/reset-demo.sh (make reset).
#
# Configuration (environment):
#   RESTART_TIMEOUT  seconds to wait for Odoo to answer again  (default 900)
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPT_NAME=restart
# shellcheck source=scripts/lib-instance.sh
. ./scripts/lib-instance.sh

: "${RESTART_TIMEOUT:=900}"

command -v docker >/dev/null || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"
[ -f compose.yaml ] || die "compose.yaml not found in $PWD"

check_compose_config

before="$(docker compose ps -q odoo || true)"

log "applying .env and compose changes"
docker compose up -d

after="$(docker compose ps -q odoo)"
[ -n "$after" ] || die "the odoo container did not start"

if [ -n "$before" ] && [ "$before" = "$after" ]; then
    # Nothing in .env justified a new container, so Odoo is still the process
    # started before the edit: restart it so it re-reads config/odoo.conf.
    log "no .env change to apply — restarting Odoo to re-read config/odoo.conf"
    docker compose restart odoo
elif [ -n "$before" ]; then
    log "container recreated: .env changes are live"
else
    log "instance was not running — started it"
fi

wait_healthy "$RESTART_TIMEOUT"

log "done — data untouched"
