# OdooPLM

Ready-to-run images of **[OdooPLM](https://github.com/OmniaGit/odooplm)** — the open
source PLM/PDM suite for [Odoo](https://www.odoo.com/), by
[OmniaSolutions](https://www.omniasolutions.website).

One command gives you a working PLM server: the database is created and the `plm`
module installed on first boot.

```bash
docker network create odooplm-net

docker run -d --name db --network odooplm-net \
    -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD=odoo -e POSTGRES_DB=postgres \
    postgres:17

docker run -d --name odooplm --network odooplm-net -p 8069:8069 -p 8072:8072 \
    -e HOST=db -e USER=odoo -e PASSWORD=odoo \
    -v odooplm-data:/var/lib/odoo \
    mboscolo/odooplm:19.0
```

Then open <http://localhost:8069>.

The recommended way is the Compose stack, which ships with sensible defaults,
persistent volumes and a folder for your own addons:

```bash
git clone --branch 19.0 https://github.com/OmniaGit/DockerOdooPLM.git odooplm
cd odooplm
docker compose up
```

## Tags

Tags follow the **Odoo version numbering**, matching the branches of the
[odooplm](https://github.com/OmniaGit/odooplm) repository.

| Tag | Odoo | Variant |
|---|---|---|
| `19.0`, `latest` | 19.0 | full |
| `19.0-slim`, `latest-slim` | 19.0 | slim |
| `18.0` | 18.0 | full |
| `18.0-slim` | 18.0 | slim |

`<version>-build<N>` tags are immutable snapshots of a single CI run; the plain
version tags are rebuilt weekly so they follow the PLM sources and the official
Odoo base image.

**full** (~4.4 GB) includes the CAD conversion stack — `cadquery`/OCP/vtk, `ezdxf`,
`matplotlib`, `numpy-stl`, `to-3mf` — required by `plm_automated_convertion`
(STEP → 3MF / STL / PNG batch conversion).
**slim** (~2.5 GB) runs the whole suite except that one module, which is the only
one importing those packages.

Both variants ship **all community OdooPLM modules** in the addons path —
`plm_web_3d`, `plm_engineering`, `plm_spare`, `plm_pack_and_go`, `plm_web_revision`,
`plm_date_bom`, … — visible in *Apps* and installable in one click. The two
Enterprise-only modules are excluded.

## Configuration

Beyond the standard Odoo image variables (`HOST`, `PORT`, `USER`, `PASSWORD`,
`PASSWORD_FILE`), the entrypoint reads:

| Variable | Default | Meaning |
|---|---|---|
| `ODOOPLM_DB` | `odooplm` | database created on first boot |
| `ODOOPLM_INIT_MODULES` | `plm` | comma separated modules installed in it |
| `ODOOPLM_WITH_DEMO` | `0` | `1` loads the Odoo demo data |
| `ODOOPLM_INIT_LANG` | *(empty)* | extra language to load, e.g. `it_IT` |
| `ODOOPLM_AUTO_INIT` | `1` | `0` disables the automatic database creation |
| `ODOOPLM_DB_TIMEOUT` | `60` | seconds to wait for PostgreSQL |

Paths inside the image:

| Path | Content |
|---|---|
| `/mnt/odooplm-addons` | the PLM modules |
| `/mnt/extra-addons` | mount your own addons here |
| `/etc/odoo/odoo.conf` | Odoo configuration |
| `/var/lib/odoo` | filestore (use a volume) |
| `/etc/odooplm-build-info` | repository, branch and commit packaged in the image |

Ports: `8069` web, `8072` websocket (chatter and 3D viewer).

> Before exposing the server: change `admin_passwd` in `odoo.conf`, set
> `list_db = False`, use a real database password and put a TLS reverse proxy in
> front.

## Links

* Packaging, Compose stacks and documentation: <https://github.com/OmniaGit/DockerOdooPLM>
* PLM modules: <https://github.com/OmniaGit/odooplm>
* User documentation: <https://odooplm.omniasolutions.website>
* CAD client (SolidWorks, SolidEdge, Inventor, AutoCAD, FreeCAD…): <https://sourceforge.net/projects/openerpplm/>
* Commercial support: **info@omniasolutions.eu**

## License

AGPL-3, like the OdooPLM modules.
