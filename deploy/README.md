# Demo server, rebuilt every Sunday night

How to run the OdooPLM 20.0 demo instance on a Linux server so that every Sunday
at 23:30 it deletes its data and comes back exactly as it was on the first boot.

TLS and the public hostname are **not** handled here. Odoo is published on
`127.0.0.1` only; putting your own reverse proxy (nginx, Traefik, HAProxy…) in
front of it is your job — see [What your reverse proxy
needs](#what-your-reverse-proxy-needs) at the end.

What is in this folder:

| File | Role |
|---|---|
| `install.sh` | does the whole setup below in one command |
| `env.demo-server.example` | the `.env` to copy to the repository root |
| `odoo.public.conf` | `config/odoo.conf` hardened for a server |
| `odooplm-reset.service` | the reset, as a systemd oneshot unit |
| `odooplm-reset.timer` | when it runs |

The reset itself is [`scripts/reset-demo.sh`](../scripts/reset-demo.sh), also
available as `make reset`.

---

## Requirements

* A Linux server (Debian 12 / Ubuntu 22.04+ / RHEL 9 all work), 4 GB RAM
  minimum — 8 GB if you keep the full CAD image — and ~15 GB of free disk.
* Docker Engine with the Compose plugin.
* **Root.** Every command on this page is written to be run as root, because a
  stock Debian does not install `sudo` at all — become root with `su -` first.
  (Prefix them with `sudo` instead if your server does have it.)

Install Docker from the official repository (the distribution packages are often
too old for `docker compose`):

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

## The short way

```bash
git clone --branch 20.0 https://github.com/OmniaGit/DockerOdooPLM.git /opt/odooplm-20
cd /opt/odooplm-20
./deploy/install.sh
```

It writes the two files a clone cannot carry, generates the database and master
passwords itself, points the systemd units at wherever you cloned the
repository, starts the stack and checks the demo data really landed. It never
overwrites a `.env` or an `odoo.conf` you have already adapted, so running it
twice is safe. `--help` lists the options (`--schedule`, `--image`,
`--no-timer`, `--no-start`, `--force-config`).

The rest of this page is the same install done by hand, and everything you need
afterwards.

## 1. Get the code

```bash
git clone --branch 20.0 https://github.com/OmniaGit/DockerOdooPLM.git /opt/odooplm-20
cd /opt/odooplm-20
```

`/opt/odooplm-20` is the path written in `odooplm-reset.service`; if you clone
somewhere else, edit `WorkingDirectory` and `ExecStart` in that file. (`install.sh`
does that substitution for you.)

## 2. Configure

```bash
cp deploy/env.demo-server.example .env
cp deploy/odoo.public.conf config/odoo.conf
nano .env               # POSTGRES_PASSWORD
nano config/odoo.conf   # admin_passwd
```

Two values must change before the first start — both marked `CHANGE-ME`:

| Where | Value | Why |
|---|---|---|
| `.env` | `POSTGRES_PASSWORD` | `odoo`/`odoo` on a server is an open database |
| `config/odoo.conf` | `admin_passwd` | it guards the database manager |

Generate them with `openssl rand -base64 24`.

Two settings worth knowing about, both already set for you:

* `ODOOPLM_IMAGE=…:20.0-demo` — the demo tag, which installs `plm_demo` (the
  LSU-100 sample product) on first boot.
* `ODOOPLM_WITH_DEMO=1` — loads Odoo's own demo data, which is what creates the
  **admin / admin** login. Without it, the sample product is there but you have
  to create the user yourself after every reset.

## 3. Start it

```bash
docker compose up -d
docker compose logs -f odoo
```

The first boot takes a few minutes: it creates the database, installs the PLM
modules and the demo product. Then check it locally, before any proxy is
involved:

```bash
curl -I http://127.0.0.1:8069/web/health     # 200
```

To confirm the demo data really landed — the LSU-100 product is 12 parts over
three BOM levels:

```bash
docker compose exec db psql -U odoo -d odooplm -tAc \
  "SELECT count(*) FROM product_template"          # 12
docker compose exec db psql -U odoo -d odooplm -tAc \
  "SELECT name FROM ir_module_module WHERE name LIKE 'plm%' AND state='installed'"
```

Expect `plm`, `plm_demo`, `plm_spare`, `plm_web_3d`. If `plm_demo` is missing,
see [If the reset fails](#if-the-reset-fails) — the same cause applies to the
first boot.

## 4. Install the weekly reset

```bash
cp deploy/odooplm-reset.service deploy/odooplm-reset.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now odooplm-reset.timer
```

Check it:

```bash
systemctl list-timers odooplm-reset.timer    # when it fires next
systemctl start odooplm-reset.service   # run it now, as a test
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

Only this compose project is touched. A reverse proxy running outside it — as a
system service or in its own compose stack — keeps serving throughout, and will
return 502 for the two minutes the rebuild takes.

### Changing the schedule

Edit `OnCalendar` in `/etc/systemd/system/odooplm-reset.timer`, then
`systemctl daemon-reload && systemctl restart odooplm-reset.timer`.

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

Nothing is lost by running it again: `systemctl start odooplm-reset.service`.

## What your reverse proxy needs

Five things, whatever proxy you use:

| | |
|---|---|
| **Upstream** | `127.0.0.1:8069` for everything |
| **Websocket** | `/websocket` must go to `127.0.0.1:8072`, with the `Upgrade`/`Connection` headers — this is the chatter and the 3D viewer |
| **Body size** | CAD documents are big. nginx defaults to 1 MB and answers 413; `client_max_body_size 1G` |
| **Timeouts** | CAD conversions and BOM imports are slow; allow ~900s |
| **Port 443** | Redirecting 80 to 443 is fine for browsers, but the CAD client must be configured on **443 over `https`** directly: its XML-RPC layer does not follow the `301` and the login fails |

Two settings in `config/odoo.conf` are part of this contract:

* `workers = 4` — **port 8072 only exists when `workers` is greater than 0.**
  At `workers = 0` there is nothing to proxy `/websocket` to and the 3D viewer
  hangs with no error in the Odoo log.
* `proxy_mode = True` — Odoo then trusts `X-Forwarded-Proto`. Your proxy must
  actually send it, or Odoo builds `http://` URLs behind your `https://`.

Worth doing on a public instance: block `/web/database/` at the proxy. The
entrypoint creates the database, so nothing needs the manager, and it is the
first thing that gets probed.

## Operating it

```bash
cd /opt/odooplm-20
make logs             # follow the Odoo logs
make reset            # wipe and rebuild now, same as the timer
docker compose ps     # odoo and db
docker compose restart odoo         # after editing config/odoo.conf
```

Updating the packaging:

```bash
git pull
docker compose up -d
```

Your `.env` is not tracked in git, so a `git pull` never overwrites it — check
`deploy/env.demo-server.example` after an update in case new variables appeared.
`config/odoo.conf` **is** tracked, so a `git pull` can conflict with your edited
copy; keep yours (`git checkout --ours config/odoo.conf`) and re-read the
example if it changed.

## Notes on the setup

**Ports.** Odoo publishes `8069`/`8072` on `127.0.0.1` only. To reach it from
your workstation without a proxy: `ssh -L 8069:127.0.0.1:8069 user@server`.

**Backups.** There are none, on purpose: this instance is designed to lose its
data every week. If something on it becomes worth keeping, it belongs on another
server — see the backup section of the [main README](../README.md#backup-and-restore).

**Firewall.** The stack itself needs no open port: only your proxy's 80/443 and
your SSH port.
