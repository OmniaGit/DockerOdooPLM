# DockerOdooPLM

Ready-to-run Docker images and Compose stacks for **[OdooPLM](https://github.com/OmniaGit/odooplm)** —
the open source PLM/PDM suite for [Odoo](https://www.odoo.com/) by
[OmniaSolutions](https://www.omniasolutions.website).

The goal of this repository is simple: **anyone should be able to get an OdooPLM
server running for testing with two commands.**

```bash
git clone --branch 19.0 https://github.com/OmniaGit/DockerOdooPLM.git odooplm && cd odooplm
docker compose up
```

Then open <http://localhost:8069> — the database is created and the `plm` module
is installed automatically on first boot.

---

## Versioning

This repository follows the **Odoo version numbering**: one git branch per Odoo
major release, matching the branch layout of the
[odooplm](https://github.com/OmniaGit/odooplm) repository itself.

| Branch | Odoo | OdooPLM branch | PostgreSQL | Image tags | Status |
|---|---|---|---|---|---|
| [`19.0`](../../tree/19.0) | 19.0 | `19.0` | 17 | `19.0`, `19.0-slim`, `latest`, `latest-slim` | current |
| [`18.0`](../../tree/18.0) | 18.0 | `18.0` | 16 | `18.0`, `18.0-slim` | supported |
| `main` | — | — | — | — | this page |

Older Odoo releases (10.0 → 17.0) exist in the `odooplm` repository but are **not**
packaged here — this repository covers Odoo 18.0 and newer.

When Odoo 20.0 is released, a `20.0` branch is created from the newest branch and
`latest` moves to it.

## Images

Every branch publishes the same two variants to **both** registries:

| Registry | Image |
|---|---|
| GitHub Container Registry | `ghcr.io/omniagit/odooplm` |
| Docker Hub | `omniasolutions/odooplm` |

| Variant | Tag | Contains | Size |
|---|---|---|---|
| **full** | `19.0` | Everything, including the CAD conversion stack (`cadquery`, `OCP`, `vtk`) needed by `plm_automated_convertion` | large (~3 GB) |
| **slim** | `19.0-slim` | All PLM modules and the 3D/2D web viewer, without the CAD conversion stack | moderate (~1.5 GB) |

Both variants ship **all community OdooPLM modules** in the addons path; only the
core `plm` module is installed automatically. Everything else is one click away in
*Apps*. The two Enterprise-only modules (`plm_pdf_workorder_enterprise`,
`plm_ent_breakages_helpdesk`) are excluded by default.

## Quick start

```bash
# pick the Odoo version you want
git clone --branch 19.0 https://github.com/OmniaGit/DockerOdooPLM.git odooplm-19
cd odooplm-19

cp .env.example .env          # optional: change ports, passwords, db name
docker compose up -d          # pulls the published image, starts Odoo + PostgreSQL
docker compose logs -f odoo
```

* Odoo: <http://localhost:8069> — default master password `admin` (change it!)
* The database `odooplm` is created on first boot with the `plm` module installed.

To build the image yourself instead of pulling it:

```bash
docker compose build          # or: make build
docker compose up -d
```

Full instructions, environment variables and troubleshooting live in the README of
each version branch.

## Repository layout (version branches)

```
Dockerfile               # OdooPLM image on top of the official odoo image
compose.yaml             # Odoo + PostgreSQL stack
.env.example             # ports, passwords, database name, auto-install modules
config/odoo.conf         # Odoo configuration used by the container
requirements/            # python dependencies of the PLM modules
scripts/                 # container entrypoint + helper scripts
addons-extra/            # drop your own addons here, they are mounted read-write
Makefile                 # make build / up / down / logs / shell / psql
.github/workflows/       # CI: build, smoke-test and publish the images
```

## Related projects

| Project | Description |
|---|---|
| [odooplm](https://github.com/OmniaGit/odooplm) | The PLM modules themselves |
| [CAD client](https://sourceforge.net/projects/openerpplm/) | Desktop connector for SolidWorks, SolidEdge, Inventor, AutoCAD, FreeCAD… |
| [Documentation](https://odooplm.omniasolutions.website) | User and administrator documentation |

## Support

* Issues about **this packaging**: open an issue in this repository.
* Issues about **the PLM modules**: <https://github.com/OmniaGit/odooplm/issues>
* Commercial support: **info@omniasolutions.eu**

## License

AGPL-3, the same license as the OdooPLM modules. See [LICENSE](LICENSE).
