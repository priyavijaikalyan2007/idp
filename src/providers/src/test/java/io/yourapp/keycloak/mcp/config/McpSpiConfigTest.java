/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 7d5128bc-ab76-4e3d-b84f-5920137159d5
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.config;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import io.yourapp.keycloak.mcp.config.McpSpiConfigException.Code;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class McpSpiConfigTest
{
    /** Base64 encoding of 32 zero bytes — a valid-length but content-trivial key. */
    private static final String VALID_32B_KEY =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    @Test
    void handoffHmacKey_missingEnvVar_throwsMissingHmacKey()
    {
        McpSpiConfig config = configFor(new HashMap<>());

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> config.handoffHmacKey("yourapp-prod"));

        assertEquals(Code.MISSING_HMAC_KEY, ex.getCode());
        assertEquals("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", ex.getParameterName());
    }

    @Test
    void handoffHmacKey_malformedBase64_throwsMalformedBase64()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", "not!valid!base64!");

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> configFor(env).handoffHmacKey("yourapp-prod"));

        assertEquals(Code.MALFORMED_BASE64, ex.getCode());
    }

    @Test
    void handoffHmacKey_wrongLength_throwsWrongKeyLengthWithActualLength()
    {
        Map<String, String> env = new HashMap<>();
        // base64 of 8 zero bytes -> 8 != 32.
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", "AAAAAAAAAAA=");

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> configFor(env).handoffHmacKey("yourapp-prod"));

        assertEquals(Code.WRONG_KEY_LENGTH, ex.getCode());
        assertTrue(ex.getMessage().contains("8"),
                "message should include the actual decoded length: " + ex.getMessage());
    }

    @Test
    void handoffHmacKey_validKey_returnsValue()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", VALID_32B_KEY);

        assertEquals(VALID_32B_KEY, configFor(env).handoffHmacKey("yourapp-prod"));
    }

    @Test
    void handoffHmacKey_realmNameNormalised_resolvesUppercaseUnderscored()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_TEST", VALID_32B_KEY);

        assertEquals(VALID_32B_KEY, configFor(env).handoffHmacKey("yourapp-test"));
    }

    @Test
    void handoffHmacKeyPrevious_unset_returnsNull()
    {
        assertNull(configFor(new HashMap<>()).handoffHmacKeyPrevious("yourapp-prod"));
    }

    @Test
    void handoffHmacKeyPrevious_set_returnsValue()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY_PREVIOUS__YOURAPP_PROD", VALID_32B_KEY);

        assertEquals(VALID_32B_KEY, configFor(env).handoffHmacKeyPrevious("yourapp-prod"));
    }

    @Test
    void handoffHmacKeyPrevious_setButMalformed_throwsMalformedBase64()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY_PREVIOUS__YOURAPP_PROD", "not!base64!");

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> configFor(env).handoffHmacKeyPrevious("yourapp-prod"));

        assertEquals(Code.MALFORMED_BASE64, ex.getCode());
    }

    @Test
    void realmsWithKeysConfigured_emptyEnv_returnsEmptySet()
    {
        assertEquals(Set.of(), configFor(new HashMap<>()).realmsWithKeysConfigured());
    }

    @Test
    void realmsWithKeysConfigured_threeRealmsConfigured_returnsThreeNamesLowercased()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", VALID_32B_KEY);
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_DEV", VALID_32B_KEY);
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_TEST", VALID_32B_KEY);
        env.put("UNRELATED_VAR", "ignore-me");
        // Previous-slot entries must NOT be reported as currently-configured realms.
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY_PREVIOUS__YOURAPP_PROD", VALID_32B_KEY);

        assertEquals(Set.of("yourapp-prod", "yourapp-dev", "yourapp-test"),
                configFor(env).realmsWithKeysConfigured());
    }

    @Test
    void normalise_realmWithHyphens_uppercasesAndReplacesHyphenWithUnderscore()
    {
        assertEquals("YOURAPP_PROD", McpSpiConfig.normalise("yourapp-prod"));
        assertEquals("YOURAPP_DEV", McpSpiConfig.normalise("yourapp-dev"));
        assertEquals("YOURAPP_TEST", McpSpiConfig.normalise("yourapp-test"));
    }

    private static McpSpiConfig configFor(Map<String, String> env)
    {
        return new McpSpiConfig(env::get, () -> env);
    }
}
