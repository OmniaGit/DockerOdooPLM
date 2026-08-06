# syntax=docker/dockerfile:1
#
# OdooPLM — https://github.com/OmniaGit/odooplm
# Image built on top of the official Odoo image, with every community PLM module
# available in the addons path.
#
#   docker build -t odooplm:19.0 .
#   docker build -t odooplm:19.0-slim --build-arg VARIANT=slim .
#
ARG ODOO_VERSION=19.0

# -----------------------------------------------------------------------------
# Stage 1 — fetch the PLM sources (git stays out of the final image)
# -----------------------------------------------------------------------------
FROM odoo:${ODOO_VERSION} AS sources

ARG ODOOPLM_REPO=https://github.com/OmniaGit/odooplm.git
ARG ODOOPLM_REF=19.0
# Full commit sha to package. Nothing in the clone command changes when odooplm
# gets a new commit, so with a layer cache the build would happily reuse the
# sources it cloned weeks ago. Pinning the sha moves the cache key with the branch
# and makes the build reproducible; CI resolves it with `git ls-remote`, local
# builds can leave it empty and get whatever the ref points at today.
ARG ODOOPLM_SHA=
# Modules that need Odoo Enterprise to be installable. Set to 1 to keep them.
ARG KEEP_ENTERPRISE_MODULES=0

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# A shallow fetch of one sha needs the full 40 characters and a server that serves
# it; anything else (an abbreviated sha, a mirror that refuses) falls back to the
# branch tip rather than failing the build.
RUN if [ -n "${ODOOPLM_SHA}" ] \
       && git init -q /src \
       && git -C /src remote add origin "${ODOOPLM_REPO}" \
       && git -C /src fetch -q --depth 1 origin "${ODOOPLM_SHA}"; then \
        git -C /src checkout -q --detach FETCH_HEAD; \
    else \
        [ -z "${ODOOPLM_SHA}" ] || echo "cannot fetch ${ODOOPLM_SHA}, taking the tip of ${ODOOPLM_REF}" >&2; \
        rm -rf /src; \
        git clone --depth 1 --branch "${ODOOPLM_REF}" "${ODOOPLM_REPO}" /src; \
    fi \
    && echo "odooplm ${ODOOPLM_REF} at $(git -C /src rev-parse HEAD)"

WORKDIR /src

# The 3D/2D viewer ships three.js and dxf-viewer as git submodules. Only those two
# are needed — the cadquery submodule is replaced by the pip package.
RUN for sub in plm_web_3d/static/src/js/lib/three.js \
               plm_web_3d/static/src/js/lib/dxf-viewer; do \
        git submodule update --init --depth 1 "$sub" \
            || git submodule update --init "$sub"; \
    done

# three.js checks out at ~875 MB, of which the viewer uses about 30: build/ and
# src/ (the dxf-viewer imports individual modules from there), examples/jsm for the
# loaders and controls, and examples/fonts for the measurement labels.
RUN THREE=plm_web_3d/static/src/js/lib/three.js \
    && if [ -d "$THREE" ]; then \
        find "$THREE" -mindepth 1 -maxdepth 1 \
            ! -name build ! -name src ! -name examples ! -name LICENSE ! -name package.json \
            -exec rm -rf {} + \
        && find "$THREE/examples" -mindepth 1 -maxdepth 1 \
            ! -name jsm ! -name fonts -exec rm -rf {} + ; \
    fi

# Everything the viewer imports from three.js must still be there. Pruning the
# wrong directory is invisible until a browser asks for the file and gets a 404,
# so it is checked here instead.
RUN python3 - <<'PY'
import os, re, sys

root = "/src/plm_web_3d/static/src/js"
bundled = os.path.join(root, "lib/three.js")
reference = re.compile(r"""['"]([^'"]*three\.js/[^'"]+)['"]""")
missing, checked = set(), 0

for dirpath, _dirnames, filenames in os.walk(root):
    if dirpath.startswith(bundled):        # three.js's own internal imports
        continue
    for filename in filenames:
        if not filename.endswith(".js"):
            continue
        path = os.path.join(dirpath, filename)
        with open(path, errors="ignore") as fh:
            content = fh.read()
        for ref in reference.findall(content):
            if ref.startswith(("http://", "https://")):
                continue
            target = "/src" + ref if ref.startswith("/") else os.path.normpath(os.path.join(dirpath, ref))
            checked += 1
            if not os.path.exists(target):
                missing.add("%s -> %s" % (os.path.relpath(path, root), ref))

if missing:
    print("three.js files the viewer imports are missing after pruning:")
    for item in sorted(missing):
        print("   ", item)
    sys.exit(1)
print("three.js pruning verified: %d imports resolve" % checked)
PY

RUN if [ "${KEEP_ENTERPRISE_MODULES}" != "1" ]; then \
        rm -rf plm_pdf_workorder_enterprise plm_ent_breakages_helpdesk; \
    fi

# Keep a trace of what was actually packaged, drop the git metadata.
RUN mkdir -p /build-info \
    && { echo "repository=${ODOOPLM_REPO}"; \
         echo "ref=${ODOOPLM_REF}"; \
         echo "commit=$(git rev-parse HEAD)"; \
         echo "commit_date=$(git log -1 --format=%cI)"; } > /build-info/odooplm \
    && find /src -name .git -maxdepth 3 -exec rm -rf {} + \
    && rm -f /src/.gitmodules

# -----------------------------------------------------------------------------
# Stage 2 — the runtime image
# -----------------------------------------------------------------------------
FROM odoo:${ODOO_VERSION}

ARG ODOO_VERSION=19.0
ARG ODOOPLM_REF=19.0
# full = with the CAD conversion stack (cadquery/OCP/vtk), slim = without it
ARG VARIANT=full

LABEL org.opencontainers.image.title="OdooPLM" \
      org.opencontainers.image.description="Odoo ${ODOO_VERSION} with the OdooPLM (OmniaSolutions) modules" \
      org.opencontainers.image.source="https://github.com/OmniaGit/DockerOdooPLM" \
      org.opencontainers.image.url="https://odooplm.omniasolutions.website" \
      org.opencontainers.image.vendor="OmniaSolutions" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.version="${ODOO_VERSION}" \
      website.odooplm.variant="${VARIANT}" \
      website.odooplm.ref="${ODOOPLM_REF}"

USER root

# Runtime libraries needed by matplotlib and, in the full variant, by OCP/vtk.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgl1 \
        libglu1-mesa \
        libxrender1 \
        libxext6 \
        libsm6 \
        libxi6 \
        libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements/ /tmp/requirements/
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements/plm-base.txt \
    && if [ "${VARIANT}" = "full" ]; then \
           pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements/plm-cad.txt; \
       fi \
    && rm -rf /tmp/requirements

ENV ODOOPLM_ADDONS=/mnt/odooplm-addons \
    ODOOPLM_DB=odooplm \
    ODOOPLM_INIT_MODULES=plm \
    ODOOPLM_AUTO_INIT=1 \
    ODOOPLM_WITH_DEMO=0

# --chown here rather than a later `chown -R`, which would duplicate the whole
# addons tree in an extra layer.
COPY --from=sources --chown=odoo:odoo /src ${ODOOPLM_ADDONS}
COPY --from=sources /build-info/odooplm /etc/odooplm-build-info
COPY --chown=odoo:odoo config/odoo.conf /etc/odoo/odoo.conf
COPY scripts/odooplm-entrypoint.sh /usr/local/bin/odooplm-entrypoint.sh

RUN chmod +x /usr/local/bin/odooplm-entrypoint.sh \
    && mkdir -p /mnt/extra-addons \
    && chown odoo:odoo /mnt/extra-addons

EXPOSE 8069 8072

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8069/web/health', timeout=8).status == 200 else 1)"

USER odoo

ENTRYPOINT ["/usr/local/bin/odooplm-entrypoint.sh"]
CMD ["odoo"]
