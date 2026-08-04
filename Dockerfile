# syntax=docker/dockerfile:1
#
# OdooPLM — https://github.com/OmniaGit/odooplm
# Image built on top of the official Odoo image, with every community PLM module
# available in the addons path.
#
#   docker build -t odooplm:18.0 .
#   docker build -t odooplm:18.0-slim --build-arg VARIANT=slim .
#
ARG ODOO_VERSION=18.0

# -----------------------------------------------------------------------------
# Stage 1 — fetch the PLM sources (git stays out of the final image)
# -----------------------------------------------------------------------------
FROM odoo:${ODOO_VERSION} AS sources

ARG ODOOPLM_REPO=https://github.com/OmniaGit/odooplm.git
ARG ODOOPLM_REF=18.0
# Modules that need Odoo Enterprise to be installable. Set to 1 to keep them.
ARG KEEP_ENTERPRISE_MODULES=0

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${ODOOPLM_REF}" "${ODOOPLM_REPO}" /src

WORKDIR /src

# The 3D/2D viewer ships three.js and dxf-viewer as git submodules. Only those two
# are needed — the cadquery submodule is replaced by the pip package.
RUN for sub in plm_web_3d/static/src/js/lib/three.js \
               plm_web_3d/static/src/js/lib/dxf-viewer; do \
        git submodule update --init --depth 1 "$sub" \
            || git submodule update --init "$sub"; \
    done

# three.js checks out at ~875 MB; the viewer only imports build/ and examples/jsm
# plus the fonts used by the measurement labels.
RUN THREE=plm_web_3d/static/src/js/lib/three.js \
    && if [ -d "$THREE" ]; then \
        find "$THREE" -mindepth 1 -maxdepth 1 \
            ! -name build ! -name examples ! -name LICENSE ! -name package.json \
            -exec rm -rf {} + \
        && find "$THREE/examples" -mindepth 1 -maxdepth 1 \
            ! -name jsm ! -name fonts -exec rm -rf {} + ; \
    fi

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

ARG ODOO_VERSION=18.0
ARG ODOOPLM_REF=18.0
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
