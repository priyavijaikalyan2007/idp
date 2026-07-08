/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: f2e3c09c-ec2b-4745-b523-ec13f9e9c0fb
 * Repository: yourapp/idp
 * Created: 2026-07-06
 */
package io.yourapp.keycloak.mcp.integration;

import java.io.File;
import java.io.FileFilter;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import dasniko.testcontainers.keycloak.KeycloakContainer;

import io.restassured.RestAssured;
import io.restassured.http.ContentType;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import org.keycloak.admin.client.Keycloak;
import org.keycloak.admin.client.resource.ClientResource;
import org.keycloak.admin.client.resource.RealmResource;
import org.keycloak.representations.idm.ClientRepresentation;
import org.keycloak.representations.idm.ClientScopeRepresentation;
import org.keycloak.representations.idm.ComponentRepresentation;
import org.keycloak.representations.idm.RealmRepresentation;

import static org.hamcrest.Matchers.notNullValue;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * End-to-end proof of the atomic-at-registration behaviour (spec §5.8): a real
 * anonymous DCR against a real Keycloak 26.6.4, with the CRP registered as an
 * anonymous Client Registration Policy, yields a client that is already
 * fully-marked — {@code yourapp.mcp=true} attribute, the default + optional MCP
 * scopes, and a browser-flow override — <em>without</em> any {@code /mcp/consent}
 * round-trip.
 *
 * <p>This is the integration counterpart to {@code McpClientRegistrationPolicyTest}:
 * the unit test proves the marking logic against mocks; this proves Keycloak
 * actually discovers the factory (META-INF wiring), fires {@code afterRegister}
 * inside the registration transaction, and persists the mutations.
 *
 * <p>Requires Docker on the build host.
 */
@Testcontainers
class McpClientRegistrationPolicyIT
{
    private static final String REALM = "mcp-crp-it";
    private static final String FLOW_ALIAS = "browser-mcp-tenant-pick";

    private static final List<String> EXPECTED_DEFAULT_SCOPES = List.of(
            "mcp-default",
            "yourapp:read", "yourapp:comment", "yourapp:curate",
            "yourapp:write", "yourapp:share");
    private static final String EXPECTED_OPTIONAL_SCOPE = "yourapp:admin";

    @Container
    static final KeycloakContainer keycloak =
            new KeycloakContainer("quay.io/keycloak/keycloak:26.6.4")
                    .withProviderLibsFrom(findSpiJar());

    @BeforeAll
    static void seedRealm()
    {
        Keycloak admin = keycloak.getKeycloakAdminClient();

        RealmRepresentation realmRep = new RealmRepresentation();
        realmRep.setRealm(REALM);
        realmRep.setEnabled(true);
        admin.realms().create(realmRep);

        RealmResource realm = admin.realm(REALM);

        // Prerequisite scopes (setup guide D.3/D.4).
        EXPECTED_DEFAULT_SCOPES.forEach(name -> createClientScope(realm, name));
        createClientScope(realm, EXPECTED_OPTIONAL_SCOPE);

        // Prerequisite flow (setup guide D.2). The CRP only needs the alias to
        // resolve; a copy of the built-in browser flow suffices for this test.
        realm.flows().copy("browser", Map.of("newName", FLOW_ALIAS));

        // A fresh realm ships several default anonymous registration policies:
        //   - "Trusted Hosts" rejects anonymous DCR from unlisted hosts, and
        //   - "Allowed Client Scopes" rejects a DCR whose requested `scope` names
        //     scopes outside the realm's default/optional set (returns 403).
        // Since this test's DCR both comes from the container gateway IP AND
        // requests mcp-default + the author bundle (to reproduce the ERRATA-006
        // promotion path), remove ALL pre-existing registration policies so the
        // scoped DCR reaches our CRP deterministically (test-only relaxation).
        String realmId = realm.toRepresentation().getId();
        String policyType =
                "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy";
        realm.components().query(realmId, policyType)
                .forEach(c -> realm.components().component(c.getId()).remove());

        // Register the CRP as an ANONYMOUS client-registration policy. Empty
        // config exercises the policy's fallback defaults.
        ComponentRepresentation crp = new ComponentRepresentation();
        crp.setName("yourapp-mcp-registration-it");
        crp.setProviderId("yourapp-mcp-registration");
        crp.setProviderType(
                "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy");
        crp.setSubType("anonymous");
        crp.setParentId(realmId);
        realm.components().add(crp);
    }

    private static void createClientScope(RealmResource realm, String name)
    {
        ClientScopeRepresentation scope = new ClientScopeRepresentation();
        scope.setName(name);
        scope.setProtocol("openid-connect");
        realm.clientScopes().create(scope);
    }

    // ------------------------------------------------------------------ tests

    @Test
    void anonymousDcr_producesFullyMarkedMcpClient()
    {
        String clientId = registerViaDcr();

        Keycloak admin = keycloak.getKeycloakAdminClient();
        RealmResource realm = admin.realm(REALM);
        List<ClientRepresentation> found = realm.clients().findByClientId(clientId);
        assertEquals(1, found.size(), "DCR'd client must be findable by clientId");
        ClientRepresentation client = found.get(0);
        ClientResource clientResource = realm.clients().get(client.getId());

        // 1. Intrinsic MCP marker attribute.
        assertEquals("true",
                client.getAttributes().get(McpMarkers.MCP_ATTRIBUTE),
                "client must carry yourapp.mcp=true set atomically at registration");

        // 2. Default scopes (granted regardless of request).
        List<String> defaults = clientResource.getDefaultClientScopes().stream()
                .map(ClientScopeRepresentation::getName).toList();
        for (String expected : EXPECTED_DEFAULT_SCOPES)
        {
            assertTrue(defaults.contains(expected),
                    "expected default scope " + expected + " on DCR'd client; had " + defaults);
        }

        // 3. Optional scope.
        List<String> optionals = clientResource.getOptionalClientScopes().stream()
                .map(ClientScopeRepresentation::getName).toList();
        assertTrue(optionals.contains(EXPECTED_OPTIONAL_SCOPE),
                "expected optional scope " + EXPECTED_OPTIONAL_SCOPE + "; had " + optionals);

        // 4. Browser-flow override bound to browser-mcp-tenant-pick.
        Map<String, String> overrides = client.getAuthenticationFlowBindingOverrides();
        assertNotNull(overrides, "flow-binding overrides must be present");
        String browserFlowId = overrides.get("browser");
        assertNotNull(browserFlowId, "browser flow override must be set");
        String boundAlias = realm.flows().getFlow(browserFlowId).getAlias();
        assertEquals(FLOW_ALIAS, boundAlias,
                "browser flow override must point at " + FLOW_ALIAS);

        // 5. Built-in consent suppressed — the yourapp /mcp/consent wizard is the
        //    sole consent surface (ERRATA-006).
        assertTrue(!Boolean.TRUE.equals(client.isConsentRequired()),
                "consentRequired must be false so Keycloak's OAUTH_GRANT screen "
                + "does not double up the yourapp consent wizard");
    }

    /** Anonymous OIDC Dynamic Client Registration; returns the new client_id. */
    private static String registerViaDcr()
    {
        String dcrUrl = keycloak.getAuthServerUrl()
                + "/realms/" + REALM + "/clients-registrations/openid-connect";
        return RestAssured.given()
                .contentType(ContentType.JSON)
                // Send `scope` exactly like a real MCP client (Claude Code / the
                // smoke test) does. Keycloak's OIDC DCR pre-binds these as OPTIONAL
                // client scopes BEFORE the CRP runs — so this reproduces the
                // ERRATA-006 condition where addClientScope must PROMOTE an
                // already-optional binding to default. Without a `scope` field the
                // bug is invisible (nothing is pre-bound), which is why the IT
                // previously passed while prod failed.
                .body(Map.of(
                        "client_name", "it-mcp-agent",
                        "redirect_uris", List.of("https://client.example/callback"),
                        "grant_types", List.of("authorization_code"),
                        "token_endpoint_auth_method", "none",
                        "scope", "openid mcp-default yourapp:read yourapp:comment "
                                + "yourapp:curate yourapp:write yourapp:share"))
                .when()
                .post(dcrUrl)
                .then()
                .statusCode(201)
                .body("client_id", notNullValue())
                .extract()
                .path("client_id");
    }

    /** Kept in sync with {@code McpClientRegistrationPolicy.MCP_ATTRIBUTE}. */
    private static final class McpMarkers
    {
        static final String MCP_ATTRIBUTE = "yourapp.mcp";
    }

    private static List<File> findSpiJar()
    {
        File targetDir = new File("target");
        FileFilter filter = f -> f.isFile()
                && f.getName().startsWith("yourapp-keycloak-mcp-spi-")
                && f.getName().endsWith(".jar")
                && !f.getName().contains("sources")
                && !f.getName().contains("javadoc");
        File[] jars = targetDir.listFiles(filter);
        Objects.requireNonNull(jars,
                "target/ directory must exist; run mvn package before mvn verify");
        if (jars.length == 0)
        {
            throw new IllegalStateException(
                    "SPI JAR not found in " + targetDir.getAbsolutePath()
                            + " — run mvn package first");
        }
        return List.of(jars[0]);
    }
}
