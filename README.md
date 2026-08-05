# OdooPLM 18.0 — Docker

Docker image and Compose stack for **[OdooPLM](https://github.com/OmniaGit/odooplm)**
on **Odoo 18.0**, by [OmniaSolutions](https://www.omniasolutions.website).

> Other Odoo releases live in the matching branch of this repository:
> [`18.0`](../../tree/18.0) · [`19.0`](../../tree/19.0) · [index](../../tree/main)

---

## Quick start

```bash
git clone --branch 18.0 https://github.com/OmniaGit/DockerOdooPLM.git odooplm-18
cd odooplm-18
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
| Base | official `odoo:18.0` image (Ubuntu 24.04, Python 3.12) |
| PLM modules | the `18.0` branch of [OmniaGit/odooplm](https://github.com/OmniaGit/odooplm), in `/mnt/odooplm-addons` |
| Your modules | `./addons-extra` of this repository, mounted on `/mnt/extra-addons` |
| Database | PostgreSQL 16 container |
| Ports | `8069` web, `8072` websocket (chatter, 3D viewer) |
| Config | `./config/odoo.conf`, mounted on `/etc/odoo` |
| Data | named volumes `odoo-data` (filestore) and `db-data` |

All community PLM modules are shipped and visible in *Apps* — `plm_web_3d`,
`plm_engineering`, `plm_spare`, `plm_pack_and_go`, `plm_web_revision`,
`plm_automated_convertion`, `plm_date_bom`, … — but only the ones you ask for are
installed. The two Enterprise-only modules (`plm_pdf_workorder_enterprise`,
`plm_ent_breakages_helpdesk`) are removed at build time; set
`--build-arg KEEP_ENTERPRISE_MODULES=1` if you run Odoo Enterprise.

### full vs slim

| Variant | Tag | On disk | Difference |
|---|---|---|---|
| full | `18.0` | ~4.2 GB | includes the CAD conversion stack (`cadquery`/OCP/vtk, `ezdxf`, `matplotlib`, `numpy-stl`, `to-3mf`) required by `plm_automated_convertion` — STEP → 3MF / STL / PNG batch conversion |
| slim | `18.0-slim` | ~2.3 GB | every PLM module works except `plm_automated_convertion`, which refuses to install on the missing `cadquery` dependency — it is the only module importing those packages |

The `latest` tags always point at the newest Odoo release, so they are published
from the [`19.0`](../../tree/19.0) branch — pull `18.0` explicitly here.

```bash
# use the slim image
ODOOPLM_IMAGE=ghcr.io/omniagit/odooplm:18.0-slim docker compose up -d
```

Published on both registries:

```
ghcr.io/omniagit/odooplm:18.0        mboscolo/odooplm:18.0
ghcr.io/omniagit/odooplm:18.0-slim   mboscolo/odooplm:18.0-slim
```

## Configuration

All variables have working defaults; see [`.env.example`](.env.example).

| Variable | Default | Meaning |
|---|---|---|
| `ODOOPLM_IMAGE` | `ghcr.io/omniagit/odooplm:18.0` | image used by the stack |
| `ODOO_PORT` | `8069` | host port for the web interface |
| `ODOO_WEBSOCKET_PORT` | `8072` | host port for websocket/longpolling |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | `odoo` / `odoo` | database credentials |
| `ODOOPLM_DB` | `odooplm` | database created on first boot |
| `ODOOPLM_INIT_MODULES` | `plm` | modules installed in that database |
| `ODOOPLM_WITH_DEMO` | `0` | `1` loads the Odoo demo data |
| `ODOOPLM_INIT_LANG` | *(empty)* | extra language to load, e.g. `it_IT` |
| `ODOOPLM_AUTO_INIT` | `1` | `0` disables the automatic database creation |
| `ODOOPLM_VARIANT` | `full` | build argument: `full` or `slim` |
| `ODOOPLM_REF` | `18.0` | build argument: branch/tag/commit of `odooplm` to package |

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
make smoke-test       # boot, verify, tear down (same check as CI)
```

Plain docker compose works just as well:

```bash
docker compose up -d
docker compose exec odoo odoo -d odooplm --db_host db -u plm --stop-after-init
docker compose down
```

## Building it yourself

```bash
docker compose build                       # full variant
docker build --build-arg VARIANT=slim -t odooplm:18.0-slim .

# package a specific state of the PLM sources
docker build --build-arg ODOOPLM_REF=18.0 -t odooplm:18.0 .
```

The exact PLM commit baked into an image is recorded inside it:

```bash
docker run --rm --entrypoint cat ghcr.io/omniagit/odooplm:18.0 /etc/odooplm-build-info
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
docker run --rm -v odooplm18_odoo-data:/data -v "$PWD/backups:/backup" \
    busybox tar czf /backup/filestore.tgz -C /data .

# restore
docker compose exec -T db psql -U odoo -d postgres -c "CREATE DATABASE odooplm OWNER odoo"
docker compose exec -T db pg_restore -U odoo -d odooplm < backups/odooplm.dump
docker run --rm -v odooplm18_odoo-data:/data -v "$PWD/backups:/backup" \
    busybox tar xzf /backup/filestore.tgz -C /data
```

The database manager at <http://localhost:8069/web/database/manager> does the same
job through the browser (master password: `admin_passwd` from `config/odoo.conf`).

## Upgrading to Odoo 19

Odoo does not migrate community databases by itself. To move a PLM database from
18.0 to 19.0 you need the Odoo upgrade service (or OpenUpgrade) plus the PLM
migration scripts — ask **info@omniasolutions.eu**. This repository only packages
each release; it does not perform database migrations.

## CAD client

The desktop connector (SolidWorks, SolidEdge, Inventor, AutoCAD, FreeCAD…) is
distributed separately: <https://sourceforge.net/projects/openerpplm/>.
Point it at `http://<host>:8069` with the database `odooplm`.

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
