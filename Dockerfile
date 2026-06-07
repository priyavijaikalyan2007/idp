FROM quay.io/keycloak/keycloak:26.6.0 AS builder

# Build-time settings (these get compiled into the artifact)
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=local

# Custom providers (SPI JARs) and themes get COPIED in BEFORE `kc.sh build`
# so the build phase picks them up and incorporates them into the optimized
# startup. The repository must contain `./providers/` and `./themes/` directories
# next to this Dockerfile (with .gitkeep files when empty), so these COPYs
# succeed even when no JARs have been built yet.
#
# Expected contents:
#
#   ./providers/
#     knobby-keycloak-mcp-spi-{version}.jar    # Authenticator + Realm Resource
#                                              # Provider + protocol mappers
#                                              # (PRD §16.8). In scope for v1
#                                              # MCP launch.
#
#     knobby-keycloak-event-listener-{version}.jar
#                                              # Bridge Keycloak events to the
#                                              # platform event bus. PARKED;
#                                              # see PRD §15 Future Work.
#                                              # Not required for MCP v1.
#
#   ./themes/
#     knobby-theme-{version}.jar               # Keycloakify-built branded theme
#                                              # for IdP login screens. See
#                                              # KEYCLOAK_THEMING_GUIDE.md.
#                                              # Currently parked. The consent
#                                              # UX runs in Knobby web, so this
#                                              # theme only affects the IdP login
#                                              # screens, which users barely see
#                                              # in the federated flow.
COPY ./providers/ /opt/keycloak/providers/
COPY ./themes/ /opt/keycloak/themes/

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.6.0

COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Runtime settings that should default to production-safe values.
# These can still be overridden at container start.
ENV KC_HOSTNAME_STRICT=true
ENV KC_HTTP_ENABLED=true
ENV KC_PROXY_HEADERS=xforwarded
ENV KC_CACHE=local

# Runtime secrets / configuration the SPI(s) read on startup.
# These are NOT set in the image - they're mounted as env vars by the deployment
# platform (Cloud Run / Hetzner systemd / docker-compose) from Secret Manager:
#
#   KNOBBY_MCP_HANDOFF_HMAC_KEY    HMAC signing key shared between this SPI and
#                                  Knobby web's /mcp/consent backend for the
#                                  path (iii) handoff (PRD §16.8.5). Sourced
#                                  from GCP Secret Manager:
#                                  knobby-mcp-handoff-hmac-key-{env}.
#                                  Required if the MCP SPI is deployed.
#                                  Rotated quarterly with two-key overlap.
#
#   KNOBBY_WEB_HOST                Hostname of Knobby web for the picker
#                                  redirect (e.g., "prod.knobby.io").
#                                  Required if the MCP SPI is deployed.

# OCI image labels for traceability across Cloud Run revisions.
# Override --build-arg values at `docker build` time to stamp specific commits/dates.
ARG IMAGE_VERSION="dev"
ARG VCS_REF="unknown"
ARG BUILD_DATE="unknown"
ARG SPI_VERSION="none"
ARG THEME_VERSION="none"
LABEL org.opencontainers.image.title="knobby-keycloak" \
      org.opencontainers.image.description="knobby.io custom Keycloak image (26.x base)" \
      org.opencontainers.image.vendor="Outcrop Inc." \
      org.opencontainers.image.source="https://github.com/<your-org>/<your-repo>" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.knobby.keycloak.base="quay.io/keycloak/keycloak:26.6.0" \
      io.knobby.keycloak.spi.version="${SPI_VERSION}" \
      io.knobby.keycloak.theme.version="${THEME_VERSION}"

ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start", "--optimized"]
