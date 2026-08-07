# Public demo server, rebuilt every Sunday night

How to run the OdooPLM 19.0 demo instance on a Linux server, behind HTTPS, so
that every Sunday at 23:30 it deletes its data and comes back exactly as it was
on the first boot.

What is in this folder:

| File | Role |
|---|---|
| `env.demo-server.example` | the `.env` to copy to the repository root |
| `compose.proxy.yaml` | overlay adding Caddy (automatic HTTPS) in front of Odoo |
| `Caddyfile` | the proxy configuration |
| `odoo.public.conf` | `config/odoo.conf` hardened for a public server |
| `odooplm-reset.service` | the reset, as a systemd oneshot unit |
| `odooplm-reset.timer` | when it runs |

The reset itself is [`scripts/reset-demo.sh`](../scripts/reset-demo.sh), also
available as `make reset`.

---

## Requirements

* A Linux server (Debian 12 / Ubuntu 22.04+ / RHEL 9 all work), 4 GB RAM
  minimum — 8 GB if you keep the full CAD image — and ~15 GB of free disk.
* Docker Engine with the Compose plugin, ports 80 and 443 free.
* A DNS record for the public name **already pointing at the server**: Caddy
  asks Let's Encrypt for the certificate on the first start and fails without it.

Install Docker from the official repository (the distribution packages are often
too old for `docker compose`):

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

## The short way

Clone, then run the installer — it writes the two files a clone cannot carry,
installs the timer, starts the stack and checks the demo data really landed:

```bash
sudo git clone --branch 19.0 https://github.com/OmniaGit/DockerOdooPLM.git /opt/odooplm-19
cd /opt/odooplm-19
sudo ./deploy/install.sh --hostname plm-demo.example.com --email you@example.com
```

It generates the database and master passwords itself, points the systemd units
at wherever you cloned the repository, and never overwrites a `.env` or an
`odoo.conf` you have already adapted — so running it twice is safe. `--help`
lists the options (`--schedule`, `--image`, `--no-timer`, `--no-start`).

The rest of this page is the same install done by hand, and everything you need
afterwards.

## 1. Get the code

```bash
sudo git clone --branch 19.0 https://github.com/OmniaGit/DockerOdooPLM.git /opt/odooplm-19
cd /opt/odooplm-19
```

`/opt/odooplm-19` is the path hard-coded in `odooplm-reset.service`; if you
clone somewhere else, edit `WorkingDirectory` and `ExecStart` in that file.

## 2. Configure

```bash
sudo cp deploy/env.demo-server.example .env
sudo cp deploy/odoo.public.conf config/odoo.conf
sudo nano .env            # ODOOPLM_HOSTNAME, ACME_EMAIL, POSTGRES_PASSWORD
sudo nano config/odoo.conf   # admin_passwd
```

Three values must change before the first start — the file marks them
`CHANGE-ME`:

| Where | Value | Why |
|---|---|---|
| `.env` | `ODOOPLM_HOSTNAME` | the name on the certificate |
| `.env` | `POSTGRES_PASSWORD` | `odoo`/`odoo` on a public host is an open database |
| `config/odoo.conf` | `admin_passwd` | it guards the database manager |

Generate passwords with `openssl rand -base64 24`.

The `.env` sets `COMPOSE_FILE=compose.yaml:deploy/compose.proxy.yaml`, so plain
`docker compose` and every `make` target include the proxy from now on — no
`-f` to remember, and the reset script picks it up too.

Two settings worth knowing about, both already set for you:

* `ODOOPLM_IMAGE=…:19.0-demo` — the demo tag, which installs `plm_demo` (the
  LSU-100 sample product) on first boot.
* `ODOOPLM_WITH_DEMO=1` — loads Odoo's own demo data, which is what creates the
  **admin / admin** login. Without it, the sample product is there but you have
  to create the user yourself after every reset.

## 3. Start it

```bash
sudo docker compose up -d
sudo docker compose logs -f odoo
```

The first boot takes a few minutes: it creates the database, installs the PLM
modules and the demo product. When the log goes quiet, open
`https://<your hostname>` and log in with `admin` / `admin`.

If the site does not answer, look at the proxy first — a missing or wrong DNS
record is the usual cause:

```bash
sudo docker compose logs caddy
```

To confirm the demo data really landed — the LSU-100 product is 12 parts over
three BOM levels:

```bash
sudo docker compose exec db psql -U odoo -d odooplm -tAc \
  "SELECT count(*) FROM product_template"          # 12
sudo docker compose exec db psql -U odoo -d odooplm -tAc \
  "SELECT name FROM ir_module_module WHERE name LIKE 'plm%' AND state='installed'"
```

Expect `plm`, `plm_demo`, `plm_spare`, `plm_web_3d`. If `plm_demo` is missing,
see [If the reset fails](#if-the-reset-fails) — the same cause applies to the
first boot.

## 4. Install the weekly reset

```bash
sudo cp deploy/odooplm-reset.service deploy/odooplm-reset.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now odooplm-reset.timer
```

Check it:

```bash
systemctl list-timers odooplm-reset.timer    # when it fires next
sudo systemctl start odooplm-reset.service   # run it now, as a test
journalctl -u odooplm-reset.service -f       # watch it work
```

The test run is the real thing — it will wipe the instance. Do it before you
put anything on the server you would miss.

### What the reset does

`scripts/reset-demo.sh`, in order:

1. `docker compose down --volumes --remove-orphans` — stops the stack and
   deletes the `odoo-data` (filestore) and `db-data` (PostgreSQL) volumes.
2. `docker compose pull` — takes the latest published demo image.
3. `docker compose up -d` — the entrypoint finds no database, so it creates it
   and installs the modules again.
4. Waits for the container healthcheck to go green.
5. Checks that `plm` and `plm_demo` are actually installed in the database.
6. Drops dangling images.

It exits non-zero if the instance does not come back, so a broken reset shows up
as a failed unit in `systemctl --failed` instead of a silently dead demo.

Step 5 is not belt and braces. A healthy container only proves Odoo answers
HTTP — an instance whose module list never reached the entrypoint boots
perfectly and serves an **empty** PLM, with no error anywhere. That failure is
real: images published before the `ODOOPLM_DEFAULT_MODULES` change carry the
list in `ODOOPLM_INIT_MODULES`, which `compose.yaml` deliberately shadows, so
running one of those without pulling gives you a blank demo on Monday morning.
The check turns that into a failed unit. `RESET_EXPECT_MODULES` in
`odooplm-reset.service` sets what must be present; `make reset` on its own only
requires `plm`.

Step 2 is deliberately non-fatal: the volumes are already deleted by then, so a
registry outage restarts from the image on disk rather than leaving the server
down for a week.

What survives a reset, because it is a bind mount and not a volume:
`config/odoo.conf`, `addons-extra/`, `.env`, and the Caddy certificates in
`deploy/caddy/` — which is why they are stored there and not in a named volume.
Everything a visitor did inside Odoo is gone.

### Changing the schedule

Edit `OnCalendar` in `/etc/systemd/system/odooplm-reset.timer`, then
`sudo systemctl daemon-reload && sudo systemctl restart odooplm-reset.timer`.

| Want | `OnCalendar=` |
|---|---|
| Sunday evening (default) | `Sun *-*-* 23:30:00` |
| The night from Sunday to Monday | `Mon *-*-* 03:00:00` |
| Every night | `*-*-* 03:00:00` |
| Twice a week | `Wed,Sun *-*-* 23:30:00` |

If the server clock is not in your timezone, append it:
`OnCalendar=Sun *-*-* 23:30:00 Europe/Rome`. Test any expression with
`systemd-analyze calendar 'Sun *-*-* 23:30:00'`.

To keep the instance on a fixed image instead of pulling the newest one every
week, add `Environment=RESET_PULL=0` to the `[Service]` section of
`odooplm-reset.service` and pin `ODOOPLM_IMAGE` to a digest in `.env` — pin the
digest, or `RESET_PULL=0` will pair a stale local image with the module
shadowing described above.

### If the reset fails

```bash
systemctl --failed                        # is odooplm-reset there?
journalctl -u odooplm-reset.service -n 50 # why
```

| Message | Meaning |
|---|---|
| `module 'plm_demo' is not installed … the instance is up but empty` | the image in use predates `ODOOPLM_DEFAULT_MODULES`. `docker compose pull` then `make reset`, or set `ODOOPLM_INIT_MODULES=plm,plm_spare,plm_web_3d,plm_demo` in `.env` |
| `timed out waiting for the instance` | the module install is still running or crashed — `docker compose logs odoo` |
| `WARNING: pull failed` | registry unreachable; the instance restarted from the local image, which is fine |

Nothing is lost by running it again: `sudo systemctl start odooplm-reset.service`.

## Operating it

```bash
cd /opt/odooplm-19
make logs             # follow the Odoo logs
make reset            # wipe and rebuild now, same as the timer
docker compose ps     # odoo, db and caddy
docker compose restart odoo         # after editing config/odoo.conf
docker compose restart caddy        # after editing deploy/Caddyfile
```

Updating the packaging (new compose file, new proxy config):

```bash
sudo git pull
sudo docker compose up -d
```

Your `.env` and `config/odoo.conf` are not tracked in git, so a `git pull` never
overwrites them — check `deploy/env.demo-server.example` after an update in case
new variables appeared.

## Notes on the setup

**Ports.** Odoo publishes `8069`/`8072` on `127.0.0.1` only; the internet
reaches it through Caddy, which talks to the container over the compose network.
To open the raw port from your workstation:
`ssh -L 8069:127.0.0.1:8069 user@server`.

**Workers.** `deploy/odoo.public.conf` sets `workers = 4`, which is what makes
Odoo serve the websocket on port `8072` — the port `deploy/Caddyfile` routes
`/websocket` to, and what the chatter and the 3D viewer need. If you drop back
to `workers = 0`, remove the `@websocket` block from the Caddyfile as well, or
the viewer will hang. Size it as `(2 × cores) + 1`.

**Database manager.** The Caddyfile answers 403 on `/web/database/*`, and
`list_db = False` hides the database list. The entrypoint creates the database,
so nothing on the server needs the manager. Delete the `@dbmanager` block if you
want to restore backups through the browser.

**Backups.** There are none, on purpose: this instance is designed to lose its
data every week. If something on it becomes worth keeping, it belongs on another
server — see the backup section of the [main README](../README.md#backup-and-restore).

**Firewall.** Only 80, 443 and your SSH port need to be open:

```bash
sudo ufw allow 80,443/tcp && sudo ufw allow OpenSSH && sudo ufw enable
```
