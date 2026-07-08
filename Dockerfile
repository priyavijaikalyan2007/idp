FROM quay.io/keycloak/keycloak:26.6.4 AS builder

# Build-time settings (these get compiled into the artifact)
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=local

# Custom providers (SPI JARs) and themes get COPIED in BEFORE `kc.sh build`
# so the build phase picks them up and incorporates them into the optimized
# startup. The repository's /target/ directory is the unified deliverable
# output location (Maven/Java convention, elevated to the repo root rather
# than per-module). build.sh stages JARs from src/providers/target/ and any
# theme builds to /target/providers/ and /target/themes/ respectively. The
# directories must exist at Docker build time even if empty — build.sh's
# mkdir -p ensures this.
#
# Expected contents:
#
#   ./target/providers/
#     yourapp-keycloak-mcp-spi-{version}.jar    # Authenticator + Realm Resource
#                                              # Provider + protocol mappers
#                                              # (PRD §16.8). In scope for v1
#                                              # MCP launch.
#
#     yourapp-keycloak-event-listener-{version}.jar
#                                              # Bridge Keycloak events to the
#                                              # platform event bus. PARKED;
#                                              # see PRD §15 Future Work.
#                                              # Not required for MCP v1.
#
#   ./target/themes/
#     yourapp-theme-{version}.jar               # Keycloakify-built branded theme
#                                              # for IdP login screens. See
#                                              # KEYCLOAK_THEMING_GUIDE.md.
#                                              # Currently parked. The consent
#                                              # UX runs in YourApp web, so this
#                                              # theme only affects the IdP login
#                                              # screens, which users barely see
#                                              # in the federated flow.
COPY ./target/providers/ /opt/keycloak/providers/
COPY ./target/themes/    /opt/keycloak/themes/

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.6.4

COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Runtime settings that should default to production-safe values.
# These can still be overridden at container start.
ENV KC_HOSTNAME_STRICT=true
ENV KC_HTTP_ENABLED=true
ENV KC_PROXY_HEADERS=xforwarded
ENV KC_CACHE=local

# Runtime secrets / configuration the SPI(s) read on startup.
# These are NOT set in the image - they're mounted as env vars by the deployment
# platform (Cloud Run / Hetzner systemd / docker-compose) from Secret Manager.
#
# Per-realm HMAC keys — one set per realm hosted by this Keycloak instance
# (one Keycloak hosts yourapp-prod, yourapp-dev, yourapp-test; each realm holds
# its OWN HMAC key for cross-realm isolation):
#
#   YOURAPP_MCP_HANDOFF_HMAC_KEY__<R>          Current HMAC key for realm <R>,
#                                              where <R> is the realm name
#                                              uppercased with - replaced by _
#                                              (yourapp-prod -> YOURAPP_PROD).
#                                              Base64-encoded 32 bytes. Sourced
#                                              from GCP Secret Manager secret
#                                              yourapp-mcp-handoff-hmac-key-<realm>.
#                                              Required for each realm using
#                                              the MCP SPI. Rotated quarterly
#                                              with two-key overlap per realm.
#
#   YOURAPP_MCP_HANDOFF_HMAC_KEY_PREVIOUS__<R> Previous HMAC key during a
#                                              rotation overlap window. Removed
#                                              once all in-flight tokens have
#                                              expired (15 min margin).
#
# The YourApp web hostname is configured per-realm via the Keycloak admin
# console as an Authenticator config property (yourapp.web.host), NOT as an env
# var — it varies by realm and is non-sensitive routing config that lives next
# to the realm's flow definition.
#
# See specs/keycloak.spi.mcp.md §7 and specs/keycloak-hmac-operations-guide.md.

# OCI image labels for traceability across Cloud Run revisions.
# Override --build-arg values at `docker build` time to stamp specific commits/dates.
ARG IMAGE_VERSION="dev"
ARG VCS_REF="unknown"
ARG BUILD_DATE="unknown"
ARG SPI_VERSION="none"
ARG THEME_VERSION="none"
LABEL org.opencontainers.image.title="yourapp-keycloak" \
      org.opencontainers.image.description="yourapp.com custom Keycloak image (26.x base)" \
      org.opencontainers.image.vendor="Outcrop Inc." \
      org.opencontainers.image.source="https://github.com/<your-org>/<your-repo>" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.yourapp.keycloak.base="quay.io/keycloak/keycloak:26.6.4" \
      io.yourapp.keycloak.spi.version="${SPI_VERSION}" \
      io.yourapp.keycloak.theme.version="${THEME_VERSION}"

ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start", "--optimized"]
