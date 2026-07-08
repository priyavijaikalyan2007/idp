/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 68c4da7a-a8df-49d4-afab-336059eee008
 * Repository: knobby/idp
 * Created: 2026-06-08
 */
package io.knobby.keycloak.mcp.integration;

import java.io.File;
import java.io.FileFilter;
import java.util.List;
import java.util.Objects;

import dasniko.testcontainers.keycloak.KeycloakContainer;

import io.restassured.RestAssured;
import io.restassured.response.Response;

import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Integration test verifying the SPI JAR loads into a real Keycloak 26.6.4
 * container and the {@code mcp-picker-callback} endpoint is reachable.
 *
 * <p>Failure modes this catches: JAR is malformed, classes fail to load,
 * the RealmResourceProvider factory doesn't register, the
 * {@code META-INF/services} files are missing, the resource provider's
 * factory id mismatches the URL path. These are exactly the deployment
 * regressions that smoke tests against a deployed environment would also
 * catch — running them at build time fails fast in CI before any deploy.
 *
 * <p>The IT does <strong>not</strong> drive a full OAuth flow — that would
 * need a federated IdP mock, browser cookies, the embedded Knobby web
 * consent mock, and tab-id round-tripping. Those slot into a future expanded
 * IT once the smoke layer is healthy. The single test here proves the JAR
 * loads and the SPI registers, which is the load-bearing deployment claim.
 *
 * <p>Requires Docker on the build host. Failsafe will fail the build if
 * Docker is unavailable, signalling that the IT needs to run on a Docker-
 * capable runner. (Future: a {@code @EnabledIfDockerAvailable} guard.)
 */
@Testcontainers
class McpSpiLoadingIT
{
    @Container
    static final KeycloakContainer keycloak =
            new KeycloakContainer("quay.io/keycloak/keycloak:26.6.4")
                    .withProviderLibsFrom(findSpiJar());

    /**
     * Locates the freshly-built SPI JAR in {@code target/}. Failsafe runs in
     * the verify phase, after package, so the JAR is guaranteed to exist by
     * the time this static initialiser runs.
     */
    private static List<File> findSpiJar()
    {
        File targetDir = new File("target");
        FileFilter filter = f -> f.isFile()
                && f.getName().startsWith("knobby-keycloak-mcp-spi-")
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

    /**
     * Hits {@code GET /realms/master/mcp-picker-callback} with no query
     * parameters. If the SPI's RealmResourceProvider is registered, the
     * handler runs and returns the SPI-specific 400 with body containing
     * {@code "missing_token"}. If the provider is NOT registered, Keycloak
     * returns a 404 with no such body.
     *
     * <p>Distinguishing those two outcomes is the entire point of this test.
     */
    @Test
    void mcpPickerCallback_endpointRegistered_returns400MissingToken()
    {
        String url = keycloak.getAuthServerUrl()
                + "/realms/master/mcp-picker-callback";
        Response response = RestAssured.given().when().get(url);

        String body = response.getBody().asString();
        assertEquals(400, response.statusCode(),
                "expected SPI's 400 missing_token; got status="
                        + response.statusCode() + " body=" + body);
        assertTrue(body.contains("missing_token"),
                "expected SPI's literal error code 'missing_token' in body, was: " + body);
    }
}
