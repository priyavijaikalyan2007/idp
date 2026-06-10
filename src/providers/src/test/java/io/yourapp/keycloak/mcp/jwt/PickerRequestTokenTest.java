/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 808660a2-2f56-418b-8085-9486ff768e0b
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.jwt;

import org.junit.jupiter.api.Test;

import java.util.List;

import org.keycloak.util.JsonSerialization;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PickerRequestTokenTest
{
    @Test
    void builder_allFieldsSet_buildsTokenWithExpectedValues()
    {
        PickerRequestToken token = validBuilder().build();

        assertEquals("keycloak-mcp-spi", token.getIss());
        assertEquals("yourapp-web-mcp-consent", token.getAud());
        assertEquals("user-sub-123", token.getSub());
        assertEquals("client-abc", token.getMcpClientId());
        assertEquals(List.of("yourapp:read", "yourapp:write"), token.getMcpRequestedScopes());
        assertEquals("auth-sess-1", token.getAuthSessionId());
        assertEquals("kc-client-1", token.getKcClientId());
        assertEquals("tab-1", token.getKcTabId());
        assertEquals(1_749_403_200L, token.getIat());
        assertEquals(1_749_403_500L, token.getExp());
    }

    @Test
    void builder_missingRequiredString_throwsIllegalState()
    {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
                () -> validBuilder().iss(null).build());
        assertTrue(ex.getMessage().contains("iss"));
    }

    @Test
    void builder_missingMcpClientId_throwsIllegalState()
    {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
                () -> validBuilder().mcpClientId(null).build());
        assertTrue(ex.getMessage().contains("mcp_client_id"));
    }

    @Test
    void builder_nonPositiveIat_throwsIllegalState()
    {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
                () -> validBuilder().iat(0).build());
        assertTrue(ex.getMessage().contains("iat"));
    }

    @Test
    void roundTripJson_serializeThenDeserialize_preservesAllFields() throws Exception
    {
        PickerRequestToken original = validBuilder().build();

        String json = JsonSerialization.writeValueAsString(original);
        PickerRequestToken parsed =
                JsonSerialization.readValue(json, PickerRequestToken.class);

        assertEquals(original.getIss(), parsed.getIss());
        assertEquals(original.getAud(), parsed.getAud());
        assertEquals(original.getSub(), parsed.getSub());
        assertEquals(original.getYourAppSub(), parsed.getYourAppSub());
        assertEquals(original.getMcpClientId(), parsed.getMcpClientId());
        assertEquals(original.getMcpRequestedScopes(), parsed.getMcpRequestedScopes());
        assertEquals(original.getOauthState(), parsed.getOauthState());
        assertEquals(original.getAuthSessionId(), parsed.getAuthSessionId());
        assertEquals(original.getKcClientId(), parsed.getKcClientId());
        assertEquals(original.getKcTabId(), parsed.getKcTabId());
        assertEquals(original.getNonce(), parsed.getNonce());
        assertEquals(original.getJti(), parsed.getJti());
        assertEquals(original.getIat(), parsed.getIat());
        assertEquals(original.getExp(), parsed.getExp());
    }

    @Test
    void serialize_usesSnakeCaseClaimNames() throws Exception
    {
        PickerRequestToken token = validBuilder().build();
        String json = JsonSerialization.writeValueAsString(token);

        // Spot-check snake_case keys (ADR-005).
        assertTrue(json.contains("\"mcp_client_id\""), json);
        assertTrue(json.contains("\"mcp_requested_scopes\""), json);
        assertTrue(json.contains("\"yourapp_sub\""), json);
        assertTrue(json.contains("\"oauth_state\""), json);
        assertTrue(json.contains("\"auth_session_id\""), json);
        assertTrue(json.contains("\"kc_client_id\""), json);
        assertTrue(json.contains("\"kc_tab_id\""), json);
    }

    static PickerRequestToken.Builder validBuilder()
    {
        return PickerRequestToken.builder()
                .iss("keycloak-mcp-spi")
                .aud("yourapp-web-mcp-consent")
                .sub("user-sub-123")
                .yourappSub("user-sub-123")
                .mcpClientId("client-abc")
                .mcpRequestedScopes(List.of("yourapp:read", "yourapp:write"))
                .oauthState("oauth-state-xyz")
                .authSessionId("auth-sess-1")
                .kcClientId("kc-client-1")
                .kcTabId("tab-1")
                .nonce("nonce-1")
                .jti("jti-1")
                .iat(1_749_403_200L)
                .exp(1_749_403_500L);
    }
}
