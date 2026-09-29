#!/bin/bash
#
# Set up this clone as a demo server that rebuilds itself every Sunday night.
#
# Run it as root — on a stock Debian that means `su -`, not sudo:
#
#   ./deploy/install.sh
#
# It writes the two files a clone cannot carry (.env, config/odoo.conf), installs
# the systemd timer pointing at wherever this repository actually sits, starts the
# stack and checks the demo data really landed.
#
# TLS and the public hostname are not its business: Odoo is published on
# 127.0.0.1 only, and your own reverse proxy (nginx, Traefik, HAProxy…) is what
# the internet talks to. The summary at the end says where to point it.
#
# Safe to run twice: it never overwrites a .env or an odoo.conf you have already
# adapted, and it never touches the database. It only ever adds what is missing.
#
# Options:
#   --schedule EXPR    systemd OnCalendar expression for the weekly reset
#                      (default "Sun *-*-* 23:30:00")
#   --image REF        image to run (default ghcr.io/omniagit/odooplm:20.0-demo)
#   --port N           host port for Odoo (default 8069, or the next free one)
#   --ws-port N        host port for the websocket (default 8072, likewise)
#   --no-timer         configure and start, but do not install the weekly reset
#   --no-start         write the configuration only, start nothing
#   --force-config     overwrite an existing config/odoo.conf (a backup is kept)
#
# When it generates the .env it picks the next free port if the default is taken
# — a box that already runs an Odoo holds 8069. An .env you already have is never
# changed: if its port is busy the install stops and says so, because moving it
# silently would break the reverse proxy you configured against it.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCRIPT_NAME=install
# shellcheck source=scripts/lib-instance.sh
. ./scripts/lib-instance.sh

SCHEDULE="Sun *-*-* 23:30:00"
IMAGE="ghcr.io/omniagit/odooplm:20.0-demo"
WITH_TIMER=1
WITH_START=1
FORCE_CONFIG=0
EXPECT_MODULES="plm,plm_demo"
PORT_ARG=""
WS_PORT_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --schedule) SCHEDULE="${2:?--schedule needs a value}"; shift 2 ;;
        --image)    IMAGE="${2:?--image needs a value}"; shift 2 ;;
        --port)     PORT_ARG="${2:?--port needs a value}"; shift 2 ;;
        --ws-port)  WS_PORT_ARG="${2:?--ws-port needs a value}"; shift 2 ;;
        --no-timer) WITH_TIMER=0; shift ;;
        --no-start) WITH_START=0; shift ;;
        --force-config) FORCE_CONFIG=1; shift ;;
        # The header comment above is the help text: print it up to the first
        # line that is no longer a comment.
        -h|--help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' \
                       "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

# --- checks ------------------------------------------------------------------

command -v docker >/dev/null || die "docker is not installed — curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon — run me as root (su -), or add yourself to the docker group"
[ -f compose.yaml ] || die "compose.yaml not found in ${REPO} — run me from inside the clone"

# Only the systemd part needs root; --no-timer is how you test as a normal user.
# No sudo anywhere in this script: a stock Debian does not have it installed.
if [ "$WITH_TIMER" = "1" ] && [ "$(id -u)" != "0" ]; then
    die "installing the timer writes to /etc/systemd/system — run me as root (su -), or pass --no-timer"
fi

# --- .env --------------------------------------------------------------------

# 32 alphanumeric characters. Read a fixed block and trim afterwards rather than
# piping into `head -c`, which closes the pipe early and kills the producer with
# SIGPIPE — fatal under `set -o pipefail`.
newpass() {
    local out=""
    while [ "${#out}" -lt 32 ]; do
        out+="$(LC_ALL=C head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9')"
    done
    printf '%s' "${out:0:32}"
}

# Docker only discovers a busy port when it starts the container — several
# minutes in, after the image has been pulled. Settle the ports up front.
# Without ss we cannot tell, so assume free and let docker be the judge.
port_free() {
    command -v ss >/dev/null || return 0
    ! ss -ltn "sport = :${1}" 2>/dev/null | grep -q LISTEN
}
port_holder() {
    ss -ltnp "sport = :${1}" 2>/dev/null \
        | sed -n 's/.*users:((\("[^"]*"\).*/\1/p' | head -1
}
next_free_port() {
    local port="$1" limit=$(( $1 + 100 ))
    while [ "$port" -le "$limit" ]; do
        port_free "$port" && { printf '%s' "$port"; return 0; }
        port=$(( port + 1 ))
    done
    return 1
}

if [ -f .env ]; then
    log "keeping the .env already in ${REPO} (delete it to have one generated)"
    # Do not touch the ports it declares — a reverse proxy is pointed at them.
    # Just refuse to go further if they cannot be bound.
    for spec_var in ODOO_PORT ODOO_WEBSOCKET_PORT; do
        spec="$(sed -n "s/^${spec_var}=//p" .env | head -1)"
        [ -n "$spec" ] || continue
        port="${spec##*:}"
        port_free "$port" || die "${spec_var} is ${port}, and that port is already \
in use$(h="$(port_holder "$port")"; [ -n "$h" ] && echo " by ${h}") — stop that service, \
or edit ${spec_var} in .env and point your reverse proxy at the new port."
    done
else
    log "writing .env"
    web_port="${PORT_ARG:-8069}"
    ws_port="${WS_PORT_ARG:-8072}"

    # A box that already runs an Odoo holds 8069/8072. Step aside rather than
    # failing — but never silently past a port the operator asked for.
    for role in web ws; do
        [ "$role" = web ] && { port="$web_port"; forced="$PORT_ARG"; } \
                          || { port="$ws_port";  forced="$WS_PORT_ARG"; }
        port_free "$port" && continue
        holder="$(port_holder "$port")"
        [ -z "$forced" ] || die "port ${port} is already in use${holder:+ by ${holder}} \
— you asked for it explicitly, so I am not moving it."
        free="$(next_free_port $(( port + 100 )))" \
            || die "port ${port} is in use${holder:+ by ${holder}} and nothing is free \
near $(( port + 100 )) either — pass --port / --ws-port with a port you know is free."
        log "port ${port} is in use${holder:+ by ${holder}} — using ${free} instead"
        [ "$role" = web ] && web_port="$free" || ws_port="$free"
    done

    pg_password="$(newpass)"
    # Values are alphanumeric by construction, so a plain | delimiter is safe.
    sed -e "s|^ODOOPLM_IMAGE=.*|ODOOPLM_IMAGE=${IMAGE}|" \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_password}|" \
        -e "s|^ODOO_PORT=.*|ODOO_PORT=127.0.0.1:${web_port}|" \
        -e "s|^ODOO_WEBSOCKET_PORT=.*|ODOO_WEBSOCKET_PORT=127.0.0.1:${ws_port}|" \
        deploy/env.demo-server.example > .env
    # It holds the database password.
    chmod 600 .env
fi

# --- config/odoo.conf --------------------------------------------------------

# The clone carries the *test* config: admin_passwd = admin, list_db = True,
# workers = 0. All three are wrong on a server, and workers = 0 also kills the
# websocket the 3D viewer needs. Replace it while it is still that file.
if [ "$FORCE_CONFIG" = "0" ] && [ -f config/odoo.conf ] && \
   ! grep -qE '^\s*admin_passwd\s*=\s*admin\s*$' config/odoo.conf; then
    log "keeping config/odoo.conf — it is no longer the insecure default"
else
    if [ -f config/odoo.conf ]; then
        backup="config/odoo.conf.bak.$(date +%Y%m%d%H%M%S)"
        cp config/odoo.conf "$backup"
        log "previous config saved as ${backup}"
    fi
    log "writing config/odoo.conf"
    admin_password="$(newpass)"
    sed -e "s|^admin_passwd = .*|admin_passwd = ${admin_password}|" \
        deploy/odoo.public.conf > config/odoo.conf
    log "database manager password: ${admin_password}"
fi

# --- systemd -----------------------------------------------------------------

if [ "$WITH_TIMER" = "1" ]; then
    log "installing the weekly reset (${SCHEDULE})"
    # The units ship with /opt/odooplm-20 in them; point them at this clone.
    sed "s|/opt/odooplm-20|${REPO}|g" \
        deploy/odooplm-reset.service > /etc/systemd/system/odooplm-reset.service
    sed "s|^OnCalendar=.*|OnCalendar=${SCHEDULE}|" \
        deploy/odooplm-reset.timer > /etc/systemd/system/odooplm-reset.timer
    systemctl daemon-reload
    systemctl enable --now odooplm-reset.timer >/dev/null
    log "next reset: $(systemctl show odooplm-reset.timer -p NextElapseUSecRealtime --value)"
else
    log "skipping the systemd timer (--no-timer): this instance will NOT reset itself"
fi

# --- start -------------------------------------------------------------------

if [ "$WITH_START" = "0" ]; then
    log "configuration written; start it yourself with: docker compose up -d"
    exit 0
fi

# Now that .env is in place, make sure compose can actually read the project —
# a stale one from an older clone would otherwise fail every command below.
check_compose_config


log "pulling the images (this takes a while the first time: the full image is ~4.4 GB)"
docker compose pull --quiet || log "WARNING: pull failed, using whatever is on disk"

log "starting the stack"
docker compose up -d

wait_healthy 1800
verify_modules "$EXPECT_MODULES"

# Report what the ports actually ended up as, rather than assuming the defaults.
web="$(docker compose port odoo 8069 2>/dev/null || echo '127.0.0.1:8069')"
ws="$(docker compose port odoo 8072 2>/dev/null || echo '127.0.0.1:8072')"

cat <<EOF

  OdooPLM demo server ready
  -------------------------
  Odoo      http://${web}
  Websocket http://${ws}          (chatter and 3D viewer)
  Login     admin / admin
  Reset     $([ "$WITH_TIMER" = "1" ] && echo "${SCHEDULE} — systemctl list-timers odooplm-reset.timer" || echo "not installed")
  Logs      cd ${REPO} && docker compose logs -f odoo
  Rebuild   cd ${REPO} && make reset

  Point your reverse proxy at those two: everything at ${web}, and the
  /websocket route at ${ws}. Odoo is on loopback only, so until the proxy
  is configured the instance is reachable from this machine alone.

EOF
