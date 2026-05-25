FROM quay.io/keycloak/keycloak:26.6.0 AS builder

# Build-time settings (these get compiled into the artifact)
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=ispn

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.6.0

COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Runtime settings that should default to production-safe values
# These can still be overridden at container start.
ENV KC_HOSTNAME_STRICT=true
ENV KC_HTTP_ENABLED=true
ENV KC_PROXY_HEADERS=xforwarded

ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start", "--optimized"]
