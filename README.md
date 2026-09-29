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
| [`20.0`](../../tree/20.0) | 20.0 | `20.0` | 17 | `20.0`, `20.0-slim` | preview: modules still being migrated |
| [`19.0`](../../tree/19.0) | 19.0 | `19.0` | 17 | `19.0`, `19.0-slim`, `latest`, `latest-slim` | current |
| [`18.0`](../../tree/18.0) | 18.0 | `18.0` | 16 | `18.0`, `18.0-slim` | supported |
| `main` | — | — | — | — | this page |

Older Odoo releases (10.0 → 17.0) exist in the `odooplm` repository but are **not**
packaged here — this repository covers Odoo 18.0 and newer.

The `20.0` branch was created from `19.0`. `latest` stays on `19.0` until the
last OdooPLM modules are migrated to 20.0, then it moves to `20.0`.

## Images

Every branch publishes the same two variants to **both** registries:

| Registry | Image |
|---|---|
| GitHub Container Registry | `ghcr.io/omniagit/odooplm` |
| Docker Hub | `mboscolo/odooplm` |

| Variant | Tag | Contains | On disk |
|---|---|---|---|
| **full** | `19.0` | Everything, including the CAD conversion stack (`cadquery`/OCP/vtk, `ezdxf`, `matplotlib`, `numpy-stl`, `to-3mf`) needed by `plm_automated_convertion` | ~4.4 GB |
| **slim** | `19.0-slim` | The whole suite except `plm_automated_convertion` — the only module importing those packages | ~2.5 GB |

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

## Publishing the images

Each version branch carries its own `.github/workflows/build.yml`. On every push to
that branch — and once a week, so the image follows both the `odooplm` branch and
the official Odoo base image — it builds the `full` and `slim` variants, boots each
one against PostgreSQL to check that Odoo answers and the PLM modules install, and
only then pushes the tags.

To enable publishing on a fresh fork or repository:

| Where | Name | Value |
|---|---|---|
| Secrets | `DOCKERHUB_USERNAME` | Docker Hub user |
| Secrets | `DOCKERHUB_TOKEN` | Docker Hub access token, used to push the images |
| Secrets | `DOCKERHUB_PASSWORD` | optional, only for the overview page sync — see below |
| Variables | `DOCKERHUB_NAMESPACE` | your Docker Hub namespace — without it the workflow pushes to GHCR only |

They can live either in the repository (*Settings → Secrets and variables → Actions*)
or in an environment named `dockerhub`, which is what the workflows declare.

GHCR needs no configuration — the built-in `GITHUB_TOKEN` is enough. Without the
Docker Hub secrets the workflow still runs and pushes to GHCR only, with a warning.
Remember to switch the new `odooplm` package to *public* in the repository
*Packages* settings, otherwise `docker pull` asks for a login.

### Docker Hub overview page

The Docker Hub repository holds every Odoo version, so its overview page is synced
from **this** branch — [`docs/dockerhub-overview.md`](docs/dockerhub-overview.md) —
by `.github/workflows/dockerhub-description.yml`, on every push that touches that
file and on demand. Syncing it from a version branch instead would make `18.0` and
`19.0` overwrite each other's description.

Docker Hub refuses to change a repository description when authenticated with an
access token — the API answers `403 Forbidden` — so this job needs an account
password in a separate `DOCKERHUB_PASSWORD` secret. It is optional: pushing images
does not need it, and without it the job skips with a warning. The alternative is
to paste `docs/dockerhub-overview.md` into the repository description on Docker Hub
by hand, which is fine for a page that rarely changes.

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
