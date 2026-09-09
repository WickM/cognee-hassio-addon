# check=skip=SecretsUsedInArgOrEnv

FROM python:3.11-slim-bookworm

ENV \
    LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_CMD_WAIT_FOR_SERVICES=1 \
    S6_VERBOSITY=0

# Shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Addon base configuration
ARG BUILD_ARCH=amd64
# renovate: datasource=github-releases packageName=hassio-addons/bashio
ARG BASHIO_VERSION="v0.18.1"
# renovate: datasource=github-releases packageName=just-containers/s6-overlay versioning=regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\.(?<other>\d+)$
ARG S6_OVERLAY_VERSION="3.2.1.0"
# renovate: datasource=github-releases packageName=home-assistant/tempio
ARG TEMPIO_VERSION="2024.11.2"

# Cognee pin — explicitly set; "latest" is BAD for reproducible deploys.
# Bump intentionally, test add-on restart-survival before publishing.
#
# v0.2.0: bumped 0.3.6 → 1.4.2. 1.x adds `openai_compatible` as a first-class
# embedding provider (0.3.x only had it via LiteLLM fallback + tiktoken gate
# that crashed on non-OpenAI model names like `voyage-4-large`). 1.x also
# replaces Kuzu with LadybugDB as the primary graph-database backend —
# `ladybug` is pulled as a transitive cognee dep; do NOT `pip install kuzu`
# on top or you'll mix incompatible backends. The provider name `kuzu`
# remains accepted by cognee as a legacy alias (routed to the Ladybug
# adapter internally).
ARG COGNEE_VERSION="1.4.2"

RUN \
    apt-get update && apt-get install -y --no-install-recommends \
        bash \
        curl \
        ca-certificates \
        git \
        jq \
        tzdata \
        tar \
        xz-utils \
    \
    && S6_ARCH="${BUILD_ARCH}" \
    && if [ "${BUILD_ARCH}" = "amd64" ]; then S6_ARCH="x86_64"; fi \
    \
    && curl -L -s "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
        | tar -C / -Jxpf - \
    \
    && curl -L -s "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
        | tar -C / -Jxpf - \
    \
    && curl -L -s "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz" \
        | tar -C / -Jxpf - \
    \
    && curl -L -s "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-arch.tar.xz" \
        | tar -C / -Jxpf - \
    \
    # Bashio install — extract whole tree to /usr/lib/bashio, then symlink
    # the bootstrap binary at /usr/bin/bashio. Scripts that use bashio functions
    # must use the `#!/usr/bin/env bashio` shebang (not `#!/usr/bin/env bash`),
    # which makes bashio source itself automatically.
    # Archive layout: bashio-0.18.1/{lib/bashio, lib/bashio.sh, lib/*.sh, README, LICENSE}
    # `mv` strips the top-level dir, leaving /usr/lib/bashio/{lib, README, LICENSE}.
    # Symlink then points at /usr/lib/bashio/lib/bashio (the bootstrap).
    && curl -J -L -o /tmp/bashio.tar.gz \
        "https://github.com/hassio-addons/bashio/archive/${BASHIO_VERSION}.tar.gz" \
    && mkdir -p /tmp/bashio-extract \
    && tar zxvf /tmp/bashio.tar.gz --strip 1 -C /tmp/bashio-extract \
    && mkdir -p /usr/lib/bashio \
    && mv /tmp/bashio-extract/lib /usr/lib/bashio/lib \
    && ln -sf /usr/lib/bashio/lib/bashio /usr/bin/bashio \
    && rm -rf /tmp/bashio-extract /tmp/bashio.tar.gz \
    \
    && curl -L -s -o /usr/bin/tempio \
        "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_${BUILD_ARCH}" \
    && chmod a+x /usr/bin/tempio \
    \
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Install cognee (pinned) + uvicorn for the API server + MCP SDK
# v0.3.0: mcp + httpx enable the MCP server adapter that runs alongside
# cognee's FastAPI app. mcp provides FastMCP (Streamable HTTP + SSE);
# httpx is used by the adapter to call cognee's REST API internally.
# v0.3.1: pin mcp<2 — 2.x renamed FastMCP→MCPServer and changed the API.
# Our adapter uses the 1.x FastMCP API. Pin to 1.30.0 (latest 1.x).
RUN pip install --no-cache-dir \
        "cognee==${COGNEE_VERSION}" \
        "uvicorn[standard]>=0.30" \
        "mcp>=1.0,<2" \
        "httpx>=0.27"

COPY rootfs /

ENTRYPOINT ["/init"]
CMD []

ARG BUILD_VERSION \
    BUILD_DATE \
    BUILD_DESCRIPTION \
    BUILD_NAME \
    BUILD_REF \
    BUILD_REPOSITORY

LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version="${BUILD_VERSION}" \
    maintainer="Manuel <https://github.com/WickM>" \
    org.opencontainers.image.title="${BUILD_NAME}" \
    org.opencontainers.image.description="${BUILD_DESCRIPTION}" \
    org.opencontainers.image.vendor="Cognee Hass.io Add-on" \
    org.opencontainers.image.authors="Manuel <https://github.com/WickM>" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/WickM" \
    org.opencontainers.image.source="https://github.com/${BUILD_REPOSITORY}" \
    org.opencontainers.image.documentation="https://github.com/${BUILD_REPOSITORY}/blob/main/README.md" \
    org.opencontainers.image.created="${BUILD_DATE}" \
    org.opencontainers.image.revision="${BUILD_REF}" \
    org.opencontainers.image.version="${BUILD_VERSION}"
