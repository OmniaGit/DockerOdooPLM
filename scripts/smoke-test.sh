#!/usr/bin/env bash
#
# Boot the stack with a given image, wait for Odoo to answer, verify that the
# PLM modules were installed, then tear everything down.
#
#   ./scripts/smoke-test.sh odooplm:20.0
#
# Used by the CI workflow before the images are pushed.
#
set -euo pipefail

IMAGE="${1:-${ODOOPLM_IMAGE:-odooplm:20.0}}"
PROJECT="${COMPOSE_PROJECT_NAME:-odooplm-smoke}"
PORT="${ODOO_PORT:-18069}"
DB="${ODOOPLM_DB:-odooplm}"
# Modules the boot is expected to end up with. Set SMOKE_EXPECT_MODULES to check an
# image that carries its own list (the -demo tags) without forcing it through
# ODOOPLM_INIT_MODULES — forcing it would test compose, not the image.
MODULES="${SMOKE_EXPECT_MODULES:-${ODOOPLM_INIT_MODULES:-plm}}"
TIMEOUT="${SMOKE_TIMEOUT:-600}"

cd "$(dirname "$0")/.."

export ODOOPLM_IMAGE="$IMAGE"
export COMPOSE_PROJECT_NAME="$PROJECT"
export ODOO_PORT="$PORT"
export ODOO_WEBSOCKET_PORT="${ODOO_WEBSOCKET_PORT:-18072}"
export ODOOPLM_DB="$DB"
# only forwarded when the caller really set it, so the image keeps deciding otherwise
if [ -n "${ODOOPLM_INIT_MODULES:-}" ]; then export ODOOPLM_INIT_MODULES; fi

cleanup() {
    local status=$?
    if [ $status -ne 0 ]; then
        echo "--- odoo logs -------------------------------------------------"
        docker compose logs --tail 200 odoo || true
    fi
    docker compose down --remove-orphans --volumes >/dev/null 2>&1 || true
    exit $status
}
trap cleanup EXIT

echo ">>> starting $IMAGE"
docker compose up -d

echo ">>> waiting for Odoo on http://localhost:${PORT}/web/health (max ${TIMEOUT}s)"
deadline=$((SECONDS + TIMEOUT))
until curl -sSf "http://localhost:${PORT}/web/health" >/dev/null 2>&1; do
    if [ $SECONDS -ge $deadline ]; then
        echo "!!! Odoo did not answer within ${TIMEOUT}s"
        exit 1
    fi
    if [ -z "$(docker compose ps -q odoo)" ] || \
       [ "$(docker inspect -f '{{.State.Running}}' "$(docker compose ps -q odoo)")" != "true" ]; then
        echo "!!! the odoo container stopped"
        exit 1
    fi
    sleep 5
done
echo ">>> Odoo is up"

echo ">>> checking installed modules in database '${DB}'"
installed=$(docker compose exec -T db \
    psql -U "${POSTGRES_USER:-odoo}" -d "$DB" -tAc \
    "SELECT name || '=' || state FROM ir_module_module WHERE name LIKE 'plm%' AND state = 'installed' ORDER BY name")

echo "$installed"

for module in ${MODULES//,/ }; do
    if ! grep -q "^${module}=installed$" <<<"$installed"; then
        echo "!!! module '${module}' is not installed"
        exit 1
    fi
done

echo ">>> checking that every PLM module is at least loadable"
uninstallable=$(docker compose exec -T db \
    psql -U "${POSTGRES_USER:-odoo}" -d "$DB" -tAc \
    "SELECT count(*) FROM ir_module_module WHERE name LIKE 'plm%'")
echo ">>> ${uninstallable} PLM modules visible in the Apps list"
if [ "${uninstallable:-0}" -lt 10 ]; then
    echo "!!! the PLM addons path does not look right"
    exit 1
fi

echo ">>> smoke test passed for $IMAGE"
