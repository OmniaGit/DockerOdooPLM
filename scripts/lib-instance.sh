#!/bin/bash
#
# Helpers shared by install.sh and reset-demo.sh. Sourced, never executed.
# The caller is expected to have changed into the repository root already.

log() { echo "[${SCRIPT_NAME:-odooplm}] $*"; }
die() { echo "[${SCRIPT_NAME:-odooplm}] ERROR: $*" >&2; exit 1; }

# wait_healthy <seconds>
#
# Block until the odoo container reports healthy, or fail. Uses the healthcheck
# declared in compose.yaml rather than curl, so it works whatever the ports are
# bound to — on a proxied server they are on loopback only.
wait_healthy() {
    local timeout="${1:-1800}" cid status deadline
    cid="$(docker compose ps -q odoo)"
    [ -n "$cid" ] || die "the odoo container is not running"

    log "waiting up to ${timeout}s for the instance to come up"
    deadline=$((SECONDS + timeout))
    while :; do
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                  "$cid" 2>/dev/null || echo gone)"
        case "$status" in
            healthy)
                log "instance healthy after ${SECONDS} seconds"
                return 0
                ;;
            none)
                die "the odoo container has no healthcheck; cannot confirm the boot"
                ;;
            gone|unhealthy)
                docker compose logs --tail 50 odoo || true
                die "the odoo container is ${status}"
                ;;
        esac
        [ "$SECONDS" -lt "$deadline" ] || {
            docker compose logs --tail 50 odoo || true
            die "timed out waiting for the instance (last status: ${status})"
        }
        sleep 10
    done
}

# verify_modules <comma separated list>
#
# A healthy container only means Odoo answers HTTP. It says nothing about what
# is inside the database: an image whose module list did not reach the
# entrypoint boots perfectly and serves an empty PLM. Check the modules are
# really there, so a broken boot fails loudly instead of quietly handing out a
# blank instance.
verify_modules() {
    local expected="${1:-}" db_name installed module
    [ -n "$expected" ] || return 0

    log "checking the installed modules: ${expected}"
    # Read the names from the containers themselves rather than from .env, which
    # only docker compose parses.
    db_name="$(docker compose exec -T odoo printenv ODOOPLM_DB 2>/dev/null | tr -d '\r')"
    : "${db_name:=odooplm}"
    installed="$(docker compose exec -T db sh -c \
        "psql -U \"\$POSTGRES_USER\" -d '${db_name}' -tAc \
         \"SELECT name FROM ir_module_module WHERE state = 'installed'\"" | tr -d '\r')"

    for module in ${expected//,/ }; do
        grep -qx "$module" <<<"$installed" \
            || die "module '${module}' is not installed in '${db_name}' — the instance is \
up but empty. Usual cause: the image in use is older than the ODOOPLM_DEFAULT_MODULES \
change, so compose shadows the module list it carries. Pull the image again, or set \
ODOOPLM_INIT_MODULES in .env."
    done
    log "modules verified"
}
