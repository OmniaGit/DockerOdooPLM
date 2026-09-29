#!/bin/bash
#
# Remove a demo server installed by deploy/install.sh.
#
# Run it as root — on a stock Debian that means `su -`, not sudo:
#
#   ./deploy/uninstall.sh
#
# It stops the weekly timer, removes the systemd units, stops the stack and
# deletes its database and filestore. It asks for confirmation first, and prints
# exactly what it is about to destroy.
#
# What it never touches: your reverse proxy configuration, Docker itself, and
# anything outside this compose project.
#
# Options:
#   --yes            do not ask for confirmation
#   --keep-data      stop everything but keep the database and the filestore
#   --images         also delete the Odoo and PostgreSQL images (~4.9 GB)
#   --purge-clone    also delete the repository directory itself
#   --dump FILE      pg_dump the database to FILE before removing anything
#
set -euo pipefail

# --purge-clone deletes the directory this script lives in, and bash reads a
# script as it goes — so run from a copy in /tmp before touching anything.
if [ "${ODOOPLM_RELOCATED:-0}" != "1" ]; then
    for arg in "$@"; do
        if [ "$arg" = "--purge-clone" ]; then
            self="$(mktemp /tmp/odooplm-uninstall.XXXXXX.sh)"
            cat "${BASH_SOURCE[0]}" > "$self"
            export ODOOPLM_RELOCATED=1
            export ODOOPLM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
            exec bash "$self" "$@"
        fi
    done
fi
if [ "${ODOOPLM_RELOCATED:-0}" = "1" ]; then
    trap 'rm -f "${BASH_SOURCE[0]}"' EXIT
fi

REPO="${ODOOPLM_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

SCRIPT_NAME=uninstall
# shellcheck source=scripts/lib-instance.sh
. "${REPO}/scripts/lib-instance.sh"

ASSUME_YES=0
KEEP_DATA=0
WITH_IMAGES=0
PURGE_CLONE=0
DUMP_TO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)      ASSUME_YES=1; shift ;;
        --keep-data)   KEEP_DATA=1; shift ;;
        --images)      WITH_IMAGES=1; shift ;;
        --purge-clone) PURGE_CLONE=1; shift ;;
        --dump)        DUMP_TO="${2:?--dump needs a file name}"; shift 2 ;;
        -h|--help) awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' \
                       "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

command -v docker >/dev/null || die "docker is not installed — nothing to remove"
cd "$REPO" 2>/dev/null || die "cannot enter ${REPO}"

# The compose project name decides what gets removed when compose itself cannot
# be used (a deleted .env, a broken compose file).
# Guarded by -f: sed exits 2 on a missing file, and under `set -e` with pipefail
# that would kill the script here — silently, before anything is removed.
PROJECT=""
if [ -f .env ]; then
    PROJECT="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | tr -d '"'\''' | head -1)"
fi
: "${PROJECT:=odooplm20}"

UNITS=(/etc/systemd/system/odooplm-reset.service /etc/systemd/system/odooplm-reset.timer)
units_present=0
for unit in "${UNITS[@]}"; do [ -e "$unit" ] && units_present=1; done

# --- what is about to happen -------------------------------------------------

echo
echo "  About to remove the OdooPLM demo installation in ${REPO}"
echo "  compose project: ${PROJECT}"
echo
[ "$units_present" = "1" ] \
    && echo "    - the weekly reset timer and its systemd units" \
    || echo "    - (no systemd units installed)"
if [ "$KEEP_DATA" = "1" ]; then
    echo "    - the containers, KEEPING the database and the filestore"
else
    echo "    - the containers AND the database and filestore volumes (irreversible)"
fi
[ "$WITH_IMAGES" = "1" ]  && echo "    - the Odoo and PostgreSQL images"
[ "$PURGE_CLONE" = "1" ]  && echo "    - the directory ${REPO} itself"
[ -n "$DUMP_TO" ]         && echo "    - after dumping the database to ${DUMP_TO}"
echo
echo "  Not touched: your reverse proxy configuration, Docker itself."
echo

if [ "$ASSUME_YES" != "1" ]; then
    [ -t 0 ] || die "not a terminal: re-run with --yes if you really mean it"
    read -rp "  Type 'yes' to continue: " answer
    [ "$answer" = "yes" ] || die "aborted, nothing was removed"
fi

# --- optional dump -----------------------------------------------------------

if [ -n "$DUMP_TO" ]; then
    log "dumping the database to ${DUMP_TO}"
    db_name="$(docker compose exec -T odoo printenv ODOOPLM_DB 2>/dev/null | tr -d '\r')" || true
    : "${db_name:=odooplm}"
    docker compose exec -T db sh -c \
        "pg_dump -U \"\$POSTGRES_USER\" -Fc '${db_name}'" > "$DUMP_TO" \
        || die "the dump failed — nothing has been removed yet"
    log "dump written: $(du -h "$DUMP_TO" | cut -f1)"
fi

# --- systemd -----------------------------------------------------------------

if [ "$units_present" = "1" ]; then
    [ "$(id -u)" = "0" ] || die "removing the systemd units needs root — run me as root (su -)"
    log "stopping and removing the weekly reset"
    systemctl disable --now odooplm-reset.timer >/dev/null 2>&1 || true
    systemctl stop odooplm-reset.service >/dev/null 2>&1 || true
    rm -f "${UNITS[@]}"
    systemctl daemon-reload
else
    log "no systemd units to remove"
fi

# --- containers and volumes --------------------------------------------------

down_args=(--remove-orphans)
[ "$KEEP_DATA" = "1" ] || down_args+=(--volumes)

log "stopping the stack"
if ! docker compose down "${down_args[@]}"; then
    # A missing .env or an edited compose file must not leave containers behind:
    # fall back to the labels compose puts on everything it creates.
    log "compose could not do it — removing by project label instead"
    docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}" \
        | xargs -r docker rm -f >/dev/null
    if [ "$KEEP_DATA" != "1" ]; then
        docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" \
            | xargs -r docker volume rm >/dev/null
    fi
    docker network rm "${PROJECT}_default" >/dev/null 2>&1 || true
fi

# --- images ------------------------------------------------------------------

if [ "$WITH_IMAGES" = "1" ]; then
    image=""
    [ -f .env ] && image="$(sed -n 's/^ODOOPLM_IMAGE=//p' .env | head -1)"
    : "${image:=ghcr.io/omniagit/odooplm:20.0-demo}"
    log "removing the images"
    docker image rm "$image" postgres:17 >/dev/null 2>&1 \
        || log "some images were already gone, or are still used by another stack"
fi

# --- the clone ---------------------------------------------------------------

if [ "$PURGE_CLONE" = "1" ]; then
    log "deleting ${REPO}"
    cd /
    rm -rf "$REPO"
fi

# --- what is left ------------------------------------------------------------

echo
log "done. What is left of it:"
left_containers="$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}" | wc -l)"
left_volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" | wc -l)"
echo "    containers: ${left_containers}"
echo "    volumes:    ${left_volumes}$([ "$KEEP_DATA" = "1" ] && echo '  (kept on purpose: --keep-data)')"
echo "    units:      $(ls /etc/systemd/system/odooplm-reset.* 2>/dev/null | wc -l)"
echo "    directory:  $([ -d "$REPO" ] && echo "$REPO" || echo 'removed')"
echo
[ "$PURGE_CLONE" = "1" ] || echo "  The clone is still there; delete it with: rm -rf ${REPO}"
[ "$WITH_IMAGES" = "1" ] || echo "  Images kept (~4.9 GB); free them with: docker image rm ghcr.io/omniagit/odooplm:20.0-demo postgres:17"
echo "  Your nginx vhost still points here — remove it and reload nginx."
echo
