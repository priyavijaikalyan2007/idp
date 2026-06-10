/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: a96ae428-d916-486d-9b49-34826e012ef2
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

class PickerResultTokenTest
{
    @Test
    void builder_allFieldsSet_buildsTokenWithExpectedValues()
    {
        PickerResultToken token = validBuilder().build();

        assertEquals("yourapp-web-mcp-consent", token.getIss());
        assertEquals("keycloak-mcp-spi", token.getAud());
        assertEquals("req-jti-1", token.getPickerRequestJti());
        assertEquals("user-sub-123", token.getUserSubEcho());
        assertEquals("tenant-uuid-1", token.getChosenTenantId());
        assertEquals(List.of("yourapp:read"), token.getGrantedScopes());
        assertEquals("oauth-state-xyz", token.getOauthState());
    }

    @Test
    void builder_missingChosenTenantId_throwsIllegalState()
    {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
                () -> validBuilder().chosenTenantId(null).build());
        assertTrue(ex.getMessage().contains("chosen_tenant_id"));
    }

    @Test
    void builder_missingPickerRequestJti_throwsIllegalState()
    {
        IllegalStateException ex = assertThrows(IllegalStateException.class,
                () -> validBuilder().pickerRequestJti(null).build());
        assertTrue(ex.getMessage().contains("picker_request_jti"));
    }

    @Test
    void roundTripJson_serializeThenDeserialize_preservesAllFields() throws Exception
    {
        PickerResultToken original = validBuilder().build();

        String json = JsonSerialization.writeValueAsString(original);
        PickerResultToken parsed =
                JsonSerialization.readValue(json, PickerResultToken.class);

        assertEquals(original.getIss(), parsed.getIss());
        assertEquals(original.getAud(), parsed.getAud());
        assertEquals(original.getPickerRequestJti(), parsed.getPickerRequestJti());
        assertEquals(original.getUserSubEcho(), parsed.getUserSubEcho());
        assertEquals(original.getChosenTenantId(), parsed.getChosenTenantId());
        assertEquals(original.getGrantedScopes(), parsed.getGrantedScopes());
        assertEquals(original.getOauthState(), parsed.getOauthState());
        assertEquals(original.getNonce(), parsed.getNonce());
        assertEquals(original.getJti(), parsed.getJti());
        assertEquals(original.getIat(), parsed.getIat());
        assertEquals(original.getExp(), parsed.getExp());
    }

    @Test
    void serialize_usesSnakeCaseClaimNames() throws Exception
    {
        PickerResultToken token = validBuilder().build();
        String json = JsonSerialization.writeValueAsString(token);

        assertTrue(json.contains("\"picker_request_jti\""), json);
        assertTrue(json.contains("\"user_sub_echo\""), json);
        assertTrue(json.contains("\"chosen_tenant_id\""), json);
        assertTrue(json.contains("\"granted_scopes\""), json);
        assertTrue(json.contains("\"oauth_state\""), json);
    }

    static PickerResultToken.Builder validBuilder()
    {
        return PickerResultToken.builder()
                .iss("yourapp-web-mcp-consent")
                .aud("keycloak-mcp-spi")
                .pickerRequestJti("req-jti-1")
                .userSubEcho("user-sub-123")
                .chosenTenantId("tenant-uuid-1")
                .grantedScopes(List.of("yourapp:read"))
                .oauthState("oauth-state-xyz")
                .authSessionId("root-auth-1")
                .kcClientId("mcp-client-abc")
                .kcTabId("tab-1")
                .nonce("nonce-2")
                .jti("res-jti-1")
                .iat(1_749_403_300L)
                .exp(1_749_403_360L);
    }
}
