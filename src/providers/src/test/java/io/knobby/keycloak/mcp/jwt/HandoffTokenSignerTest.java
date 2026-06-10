/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 39a28c20-bf07-4a48-94b0-22c12fc7b89b
 * Repository: knobby/idp
 * Created: 2026-06-08
 */
package io.knobby.keycloak.mcp.jwt;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import io.knobby.keycloak.mcp.config.McpSpiConfig;
import io.knobby.keycloak.mcp.config.McpSpiConfigException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HandoffTokenSignerTest
{
    /** Base64 of 32 zero bytes. */
    private static final String KEY_A =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    /** Base64 of 32 0x01 bytes. */
    private static final String KEY_B =
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";

    @Test
    void sign_validPayload_returnsThreePartJws()
    {
        HandoffTokenSigner signer = signerWith(Map.of(
                "KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", KEY_A));

        String jwt = signer.sign(PickerRequestTokenTest.validBuilder().build(),
                "knobby-prod");

        String[] parts = jwt.split("\\.");
        assertEquals(3, parts.length, "JWS must have header.payload.signature: " + jwt);
        // Header is base64url-encoded; decoded should include alg=HS256 and typ=JWT.
        // Tolerant of Keycloak's JSON spacing variations (e.g., "typ" : "JWT").
        String header = new String(
                java.util.Base64.getUrlDecoder().decode(parts[0]),
                java.nio.charset.StandardCharsets.UTF_8);
        String collapsed = header.replaceAll("\\s+", "");
        assertTrue(collapsed.contains("\"alg\":\"HS256\""), "header: " + header);
        assertTrue(collapsed.contains("\"typ\":\"JWT\""), "header: " + header);
    }

    @Test
    void sign_unknownRealm_throwsMissingHmacKey()
    {
        HandoffTokenSigner signer = signerWith(new HashMap<>());

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> signer.sign(PickerRequestTokenTest.validBuilder().build(),
                        "knobby-prod"));
        assertEquals(McpSpiConfigException.Code.MISSING_HMAC_KEY, ex.getCode());
    }

    @Test
    void sign_samePayloadSameRealmTwice_signaturesIdentical()
    {
        HandoffTokenSigner signer = signerWith(Map.of(
                "KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", KEY_A));

        Object payload = PickerRequestTokenTest.validBuilder().build();
        String first = signer.sign(payload, "knobby-prod");
        String second = signer.sign(payload, "knobby-prod");

        assertEquals(first, second,
                "HS256 is deterministic for the same key + payload");
    }

    @Test
    void sign_samePayloadDifferentRealms_signaturesDifferent()
    {
        HandoffTokenSigner signer = signerWith(Map.of(
                "KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", KEY_A,
                "KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_DEV", KEY_B));

        Object payload = PickerRequestTokenTest.validBuilder().build();
        String prodJwt = signer.sign(payload, "knobby-prod");
        String devJwt = signer.sign(payload, "knobby-dev");

        // Header and payload are identical (same payload); only signature differs.
        String prodSig = prodJwt.split("\\.")[2];
        String devSig = devJwt.split("\\.")[2];
        assertNotEquals(prodSig, devSig,
                "different realms hold different keys => different signatures");
    }

    private static HandoffTokenSigner signerWith(Map<String, String> env)
    {
        McpSpiConfig config = new McpSpiConfig(env::get, () -> env);
        return new HandoffTokenSigner(config);
    }
}
