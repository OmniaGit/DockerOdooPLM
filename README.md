# OdooPLM 20.0 — Docker

Docker image and Compose stack for **[OdooPLM](https://github.com/OmniaGit/odooplm)**
on **Odoo 20.0**, by [OmniaSolutions](https://www.omniasolutions.website).

> Other Odoo releases live in the matching branch of this repository:
> [`18.0`](../../tree/18.0) · [`19.0`](../../tree/19.0) · [`20.0`](../../tree/20.0) · [index](../../tree/main)

---

## Quick start

```bash
git clone --branch 20.0 https://github.com/OmniaGit/DockerOdooPLM.git odooplm-20
cd odooplm-20
docker compose up
```

Open <http://localhost:8069>.

On the first boot the entrypoint creates the database `odooplm` and installs the
`plm` module, so you land straight on a working PLM server — no database wizard,
no *Apps* hunting. Log in with the user you create in the database manager, or
with `admin` / `admin` if you enabled the demo data.

Everything is configurable, but nothing has to be: copy `.env.example` to `.env`
only when you want to change ports, passwords, the database name or the modules
installed at startup.

```bash
cp .env.example .env
docker compose up -d
docker compose logs -f odoo
```

## What is in the image

| | |
|---|---|
| Base | official `odoo:20.0` image (Ubuntu 24.04, Python 3.12) |
| PLM modules | the `20.0` branch of [OmniaGit/odooplm](https://github.com/OmniaGit/odooplm), in `/mnt/odooplm-addons` |
| Your modules | `./addons-extra` of this repository, mounted on `/mnt/extra-addons` |
| Database | PostgreSQL 17 container |
| Ports | `8069` web, `8072` websocket (chatter, 3D viewer) |
| Config | `./config/odoo.conf`, mounted on `/etc/odoo` |
| Data | named volumes `odoo-data` (filestore) and `db-data` |

All community PLM modules are shipped and visible in *Apps* — `plm_web_3d`,
`plm_engineering`, `plm_spare`, `plm_pack_and_go`, `plm_web_revision`,
`plm_automated_convertion`, `plm_date_bom`, … — but only the ones you ask for are
installed. The two Enterprise-only modules (`plm_pdf_workorder_enterprise`,
`plm_ent_breakages_helpdesk`) are removed at build time; set
`--build-arg KEEP_ENTERPRISE_MODULES=1` if you run Odoo Enterprise.

> **Migration in progress.** The `20.0` branch of odooplm does not carry every
> module yet: `plm_web_3d_sale`, `plm_suspended`, `plm_workflow_custom_action`,
> `plm_mcp_bot`, `plm_mcp_ecr` and `plm_mcp_odoo_ai` are still marked
> `installable: False` and are not offered in *Apps*. The `latest` tags stay on
> [`19.0`](../../tree/19.0) until they are migrated.

### full vs slim

| Variant | Tag | On disk | Difference |
|---|---|---|---|
| full | `20.0` | ~4.4 GB | includes the CAD conversion stack (`cadquery`/OCP/vtk, `ezdxf`, `matplotlib`, `numpy-stl`, `to-3mf`) required by `plm_automated_convertion` — STEP → 3MF / STL / PNG batch conversion |
| slim | `20.0-slim` | ~2.5 GB | every PLM module works except `plm_automated_convertion`, which refuses to install on the missing `cadquery` dependency — it is the only module importing those packages |

```bash
# use the slim image
ODOOPLM_IMAGE=ghcr.io/omniagit/odooplm:20.0-slim docker compose up -d
```

### demo data

Every variant also has a `-demo` tag. Same image, same layers — the only
difference is what the entrypoint installs on the first boot: `plm_demo`, which
fills the database with the **LSU-100** sample product (12 parts over three BOM
levels, a spare part BOM, 30 STEP/3MF/DXF/PDF documents with previews, document
relations and 3D markups).

```bash
# a populated PLM to look at, instead of an empty one
ODOOPLM_IMAGE=ghcr.io/omniagit/odooplm:20.0-demo docker compose up -d
```

It is meant for evaluation, demonstrations and training — not for production.
The plain tags stay empty and install `plm` only.

Published on both registries:

```
ghcr.io/omniagit/odooplm:20.0             mboscolo/odooplm:20.0
ghcr.io/omniagit/odooplm:20.0-slim        mboscolo/odooplm:20.0-slim
ghcr.io/omniagit/odooplm:20.0-demo        mboscolo/odooplm:20.0-demo
ghcr.io/omniagit/odooplm:20.0-slim-demo   mboscolo/odooplm:20.0-slim-demo
```

## Configuration

All variables have working defaults; see [`.env.example`](.env.example).

| Variable | Default | Meaning |
|---|---|---|
| `ODOOPLM_IMAGE` | `ghcr.io/omniagit/odooplm:20.0` | image used by the stack |
| `ODOO_PORT` | `8069` | host port for the web interface |
| `ODOO_WEBSOCKET_PORT` | `8072` | host port for websocket/longpolling |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | `odoo` / `odoo` | database credentials |
| `ODOOPLM_DB` | `odooplm` | database created on first boot |
| `ODOOPLM_INIT_MODULES` | `plm` | modules installed in that database |
| `ODOOPLM_WITH_DEMO` | `0` | `1` loads the Odoo demo data |
| `ODOOPLM_INIT_LANG` | *(empty)* | extra language to load, e.g. `it_IT` |
| `ODOOPLM_AUTO_INIT` | `1` | `0` disables the automatic database creation |
| `ODOOPLM_VARIANT` | `full` | build argument: `full` or `slim` |
| `ODOOPLM_REF` | `20.0` | build argument: branch/tag/commit of `odooplm` to package |

Want the whole suite installed from the start?

```bash
ODOOPLM_INIT_MODULES=plm,plm_web_3d,plm_engineering,plm_spare,plm_pack_and_go,plm_web_revision \
  docker compose up -d
```

Odoo settings that are not environment variables (workers, limits, master
password, `dbfilter`…) live in [`config/odoo.conf`](config/odoo.conf). Edit it and
`docker compose restart odoo`.

> **Before exposing this server:** change `admin_passwd` in `config/odoo.conf`,
> change `POSTGRES_PASSWORD`, set `list_db = False`, and put a reverse proxy with
> TLS in front (proxy `8069` and the `/websocket` route to `8072`).

## Everyday commands

A `Makefile` wraps the usual ones — `make help` lists them all.

```bash
make build            # build the image locally (VARIANT=slim for the small one)
make up / make down   # start / stop the stack (data kept)
make logs             # follow the Odoo logs
make shell            # bash inside the Odoo container
make odoo-shell       # Odoo python shell on the PLM database
make psql             # psql on the PLM database
make update MODULES=plm,plm_web_3d   # upgrade modules and restart
make destroy          # stop and DELETE the database and filestore
make reset            # destroy, pull, start again — a fresh instance
make smoke-test       # boot, verify, tear down (same check as CI)
```

Plain docker compose works just as well:

```bash
docker compose up -d
docker compose exec odoo odoo -d odooplm --db_host db -u plm --stop-after-init
docker compose down
```

## Running it as a demo server

[`deploy/`](deploy/README.md) is a complete runbook for putting this stack on a
Linux server with a systemd timer that deletes the data and rebuilds the
instance every Sunday night — visitors get a clean PLM every Monday, and
nothing anyone leaves behind survives the week.

```bash
git clone --branch 20.0 https://github.com/OmniaGit/DockerOdooPLM.git /opt/odooplm-20
cd /opt/odooplm-20
./deploy/install.sh
```

The installer writes the two files a clone cannot carry — `.env` and a
`config/odoo.conf` fit for a server — generating the passwords itself, installs
the timer and verifies the demo data landed.

Odoo is published on `127.0.0.1:8069` (and `:8072` for the websocket); TLS and
the public name are left to your own reverse proxy — see [what it
needs](deploy/README.md#what-your-reverse-proxy-needs). The proxy has to serve
**443 over `https`**: that is the port the CAD client connects to, as it does on
the public 19.0 demo at <https://v19.odooplm.cloud> (database `odooplm`); there is
no public 20.0 demo yet.

The reset itself is one script — `make reset` runs it by hand:

```bash
docker compose down --volumes   # delete the database and the filestore
docker compose pull             # take the latest demo image
docker compose up -d            # the entrypoint rebuilds everything
```

## Building it yourself

```bash
docker compose build                       # full variant
docker build --build-arg VARIANT=slim -t odooplm:20.0-slim .

# package a specific state of the PLM sources
docker build --build-arg ODOOPLM_REF=20.0 -t odooplm:20.0 .
```

The exact PLM commit baked into an image is recorded inside it:

```bash
docker run --rm --entrypoint cat ghcr.io/omniagit/odooplm:20.0 /etc/odooplm-build-info
```

## Adding your own modules

Drop them in `addons-extra/` (mounted read-write on `/mnt/extra-addons`), then:

```bash
docker compose restart odoo
docker compose exec odoo odoo -d odooplm --db_host db -i your_module --stop-after-init
```

## Backup and restore

```bash
# backup (database + filestore)
docker compose exec -T db pg_dump -U odoo -Fc odooplm > backups/odooplm.dump
docker run --rm -v odooplm20_odoo-data:/data -v "$PWD/backups:/backup" \
    busybox tar czf /backup/filestore.tgz -C /data .

# restore
docker compose exec -T db psql -U odoo -d postgres -c "CREATE DATABASE odooplm OWNER odoo"
docker compose exec -T db pg_restore -U odoo -d odooplm < backups/odooplm.dump
docker run --rm -v odooplm20_odoo-data:/data -v "$PWD/backups:/backup" \
    busybox tar xzf /backup/filestore.tgz -C /data
```

The database manager at <http://localhost:8069/web/database/manager> does the same
job through the browser (master password: `admin_passwd` from `config/odoo.conf`).

## CAD client

The desktop connector (SolidWorks, SolidEdge, Inventor, AutoCAD, FreeCAD…) is
distributed separately: <https://sourceforge.net/projects/openerpplm/>.

| | This stack | Public demo |
|---|---|---|
| Protocol | `http` | `https` |
| Host | `localhost` (or the host running it) | `v19.odooplm.cloud` (19.0) |
| Port | `8069` | `443` |
| Database | `odooplm` | `odooplm` |
| User / password | `admin` / `admin` | `admin` / `admin` |

> Once the stack is behind a TLS reverse proxy, point the client at **443 over
> `https`**, not at 80. Port 80 answers `301` to the HTTPS URL and the client's
> XML-RPC layer does not follow redirects, so the login fails.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `odoo` container restarts, logs show a database connection error | the `db` container is unhealthy — `docker compose logs db`; a stale `db-data` volume with a different password is the usual cause (`make destroy` to reset) |
| First boot takes minutes | it does: the database is being created and `plm` installed. Follow `docker compose logs -f odoo` |
| `Unable to install module ... external dependency cadquery` | you are on the `slim` image — switch `ODOOPLM_IMAGE` to the full tag |
| 3D viewer shows nothing | check the browser console; the websocket port `8072` must be reachable |
| Port already in use | set `ODOO_PORT` / `ODOO_WEBSOCKET_PORT` in `.env` |
| Database already exists but you want a fresh one | `make destroy && make up` |

## Support

* Packaging issues: open an issue in this repository.
* PLM module issues: <https://github.com/OmniaGit/odooplm/issues>
* Documentation: <https://odooplm.omniasolutions.website>
* Commercial support: **info@omniasolutions.eu**

## License

AGPL-3, like the OdooPLM modules. See [LICENSE](LICENSE).
