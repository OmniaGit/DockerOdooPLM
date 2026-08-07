#!/bin/bash
#
# Set up this clone as a public OdooPLM demo server that rebuilds itself weekly.
#
#   sudo ./deploy/install.sh --hostname plm-demo.example.com --email you@example.com
#
# It writes the two files a clone cannot carry (.env, config/odoo.conf), installs
# the systemd timer pointing at wherever this repository actually sits, starts the
# stack and checks the demo data really landed.
#
# Safe to run twice: it never overwrites a .env or an odoo.conf you have already
# adapted, and it never touches the database. It only ever adds what is missing.
#
# Options:
#   --hostname NAME    public DNS name, used for the TLS certificate (required)
#   --email ADDRESS    address Let's Encrypt warns about expiry (recommended)
#   --schedule EXPR    systemd OnCalendar expression for the weekly reset
#                      (default "Sun *-*-* 23:30:00")
#   --image REF        image to run (default ghcr.io/omniagit/odooplm:19.0-demo)
#   --no-timer         configure and start, but do not install the weekly reset
#   --no-start         write the configuration only, start nothing
#   --force-config     overwrite an existing config/odoo.conf (a backup is kept)
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCRIPT_NAME=install
# shellcheck source=scripts/lib-instance.sh
. ./scripts/lib-instance.sh

HOSTNAME_ARG=""
EMAIL=""
SCHEDULE="Sun *-*-* 23:30:00"
IMAGE="ghcr.io/omniagit/odooplm:19.0-demo"
WITH_TIMER=1
WITH_START=1
FORCE_CONFIG=0
EXPECT_MODULES="plm,plm_demo"

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname) HOSTNAME_ARG="${2:?--hostname needs a value}"; shift 2 ;;
        --email)    EMAIL="${2:?--email needs a value}"; shift 2 ;;
        --schedule) SCHEDULE="${2:?--schedule needs a value}"; shift 2 ;;
        --image)    IMAGE="${2:?--image needs a value}"; shift 2 ;;
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
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (run me with sudo, or add yourself to the docker group)"
[ -f compose.yaml ] || die "compose.yaml not found in ${REPO} — run me from inside the clone"

# Only the systemd part needs root; --no-timer is how you test as a normal user.
if [ "$WITH_TIMER" = "1" ] && [ "$(id -u)" != "0" ]; then
    die "installing the timer writes to /etc/systemd/system — re-run with sudo, or pass --no-timer"
fi

if [ -z "$HOSTNAME_ARG" ]; then
    if [ -t 0 ]; then
        read -rp "Public DNS name for this server (e.g. plm-demo.example.com): " HOSTNAME_ARG
    fi
    [ -n "$HOSTNAME_ARG" ] || die "--hostname is required: it is the name on the TLS certificate"
fi

if [ -z "$EMAIL" ] && [ -t 0 ]; then
    read -rp "Email for Let's Encrypt expiry notices (optional, Enter to skip): " EMAIL
fi

# A name that does not resolve here means Caddy cannot be issued a certificate.
# Only a warning: split-horizon DNS and NAT both make the local view unreliable.
if command -v getent >/dev/null && ! getent hosts "$HOSTNAME_ARG" >/dev/null 2>&1; then
    log "WARNING: '${HOSTNAME_ARG}' does not resolve from this machine."
    log "         Caddy needs its A/AAAA record pointing here before it can get a"
    log "         certificate. Carry on if the DNS change is still propagating."
fi

for port in 80 443; do
    if command -v ss >/dev/null && ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        log "WARNING: something is already listening on port ${port}; Caddy will fail to bind"
    fi
done

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

if [ -f .env ]; then
    log "keeping the .env already in ${REPO} (delete it to have one generated)"
else
    log "writing .env"
    pg_password="$(newpass)"
    # Values are alphanumeric by construction, so a plain | delimiter is safe.
    sed -e "s|^ODOOPLM_IMAGE=.*|ODOOPLM_IMAGE=${IMAGE}|" \
        -e "s|^ODOOPLM_HOSTNAME=.*|ODOOPLM_HOSTNAME=${HOSTNAME_ARG}|" \
        -e "s|^ACME_EMAIL=.*|ACME_EMAIL=${EMAIL}|" \
        -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_password}|" \
        deploy/env.demo-server.example > .env
    # It holds the database password.
    chmod 600 .env
fi

# --- config/odoo.conf --------------------------------------------------------

# The clone carries the *test* config: admin_passwd = admin, list_db = True,
# workers = 0. All three are wrong on a public server, and workers = 0 also kills
# the websocket the 3D viewer needs. Replace it while it is still that file.
if [ "$FORCE_CONFIG" = "0" ] && [ -f config/odoo.conf ] && \
   ! grep -qE '^\s*admin_passwd\s*=\s*admin\s*$' config/odoo.conf; then
    log "keeping config/odoo.conf — it is no longer the insecure default"
else
    if [ -f config/odoo.conf ]; then
        backup="config/odoo.conf.bak.$(date +%Y%m%d%H%M%S)"
        cp config/odoo.conf "$backup"
        log "previous config saved as ${backup}"
    fi
    log "writing config/odoo.conf for a public server"
    admin_password="$(newpass)"
    sed -e "s|^admin_passwd = .*|admin_passwd = ${admin_password}|" \
        deploy/odoo.public.conf > config/odoo.conf
    log "database manager password: ${admin_password}"
fi

# Caddy stores the certificates here. Bind mounts, so that the weekly
# `docker compose down --volumes` cannot delete them.
mkdir -p deploy/caddy/data deploy/caddy/config

# --- systemd -----------------------------------------------------------------

if [ "$WITH_TIMER" = "1" ]; then
    log "installing the weekly reset (${SCHEDULE})"
    # The units ship with /opt/odooplm-19 in them; point them at this clone.
    sed "s|/opt/odooplm-19|${REPO}|g" \
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

log "pulling the images (this takes a while the first time: the full image is ~4.4 GB)"
docker compose pull --quiet || log "WARNING: pull failed, using whatever is on disk"

log "starting the stack"
docker compose up -d

wait_healthy 1800
verify_modules "$EXPECT_MODULES"

cat <<EOF

  OdooPLM demo server ready
  -------------------------
  URL       https://${HOSTNAME_ARG}
  Login     admin / admin
  Reset     $([ "$WITH_TIMER" = "1" ] && echo "${SCHEDULE} (systemctl list-timers odooplm-reset.timer)" || echo "not installed")
  Logs      cd ${REPO} && docker compose logs -f odoo
  Rebuild   cd ${REPO} && make reset

  If the URL does not answer, the certificate is the first thing to check:
      docker compose logs caddy

EOF
