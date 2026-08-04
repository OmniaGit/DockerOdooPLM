#!/bin/bash
#
# OdooPLM entrypoint.
#
# Creates the database and installs the PLM modules on first boot, then hands over
# to the entrypoint of the official Odoo image, which keeps its usual behaviour
# (HOST/PORT/USER/PASSWORD/PASSWORD_FILE environment variables, odoo arguments...).
#
# Configuration:
#   ODOOPLM_AUTO_INIT     1 to create/initialise the database on first boot (default 1)
#   ODOOPLM_DB            database created on first boot                    (default odooplm)
#   ODOOPLM_INIT_MODULES  comma separated modules to install                (default plm)
#   ODOOPLM_WITH_DEMO     1 to load Odoo demo data                          (default 0)
#   ODOOPLM_INIT_LANG     language to load, e.g. it_IT                      (default none)
#   ODOOPLM_DB_TIMEOUT    seconds to wait for PostgreSQL                    (default 60)
#
set -e

: "${ODOOPLM_AUTO_INIT:=1}"
: "${ODOOPLM_DB:=odooplm}"
: "${ODOOPLM_INIT_MODULES:=plm}"
: "${ODOOPLM_WITH_DEMO:=0}"
: "${ODOOPLM_INIT_LANG:=}"
: "${ODOOPLM_DB_TIMEOUT:=60}"

log() { echo "[odooplm-entrypoint] $*"; }

# Same database resolution as the official image entrypoint.
if [ -n "${PASSWORD_FILE:-}" ]; then
    PASSWORD="$(< "$PASSWORD_FILE")"
fi
: "${HOST:=${DB_PORT_5432_TCP_ADDR:=db}}"
: "${PORT:=${DB_PORT_5432_TCP_PORT:=5432}}"
: "${USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:=odoo}}}"
: "${PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:=odoo}}}"

# Only initialise when the container is actually going to run an Odoo server.
should_init() {
    [ "$ODOOPLM_AUTO_INIT" = "1" ] || return 1
    [ -n "$ODOOPLM_DB" ] || return 1
    case "${1:-}" in
        ""|odoo|--) return 0 ;;
        -*) return 0 ;;
        *) return 1 ;;
    esac
}

database_exists() {
    python3 - "$HOST" "$PORT" "$USER" "$PASSWORD" "$ODOOPLM_DB" <<'PY'
import sys
import psycopg2

host, port, user, password, dbname = sys.argv[1:6]
conn = psycopg2.connect(host=host, port=port, user=user, password=password,
                        dbname="postgres", connect_timeout=10)
try:
    with conn.cursor() as cr:
        cr.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
        sys.exit(0 if cr.fetchone() else 1)
finally:
    conn.close()
PY
}

if should_init "${1:-}"; then
    log "waiting for PostgreSQL on ${HOST}:${PORT}"
    wait-for-psql.py --db_host "$HOST" --db_port "$PORT" --db_user "$USER" \
        --db_password "$PASSWORD" --timeout "$ODOOPLM_DB_TIMEOUT"

    if database_exists; then
        log "database '${ODOOPLM_DB}' already exists, skipping initialisation"
    else
        log "creating database '${ODOOPLM_DB}' with modules: ${ODOOPLM_INIT_MODULES}"
        INIT_ARGS=(
            --database "$ODOOPLM_DB"
            --init "$ODOOPLM_INIT_MODULES"
            --db_host "$HOST" --db_port "$PORT"
            --db_user "$USER" --db_password "$PASSWORD"
            --stop-after-init --no-http
        )
        if [ "$ODOOPLM_WITH_DEMO" != "1" ]; then
            INIT_ARGS+=(--without-demo=all)
        fi
        if [ -n "$ODOOPLM_INIT_LANG" ]; then
            INIT_ARGS+=(--load-language "$ODOOPLM_INIT_LANG")
        fi

        odoo "${INIT_ARGS[@]}"
        log "database '${ODOOPLM_DB}' ready"
    fi
fi

exec /entrypoint.sh "$@"
