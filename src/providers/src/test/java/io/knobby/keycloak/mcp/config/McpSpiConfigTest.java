/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 7d5128bc-ab76-4e3d-b84f-5920137159d5
 * Repository: knobby/idp
 * Created: 2026-06-08
 */
package io.knobby.keycloak.mcp.config;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import io.knobby.keycloak.mcp.config.McpSpiConfigException.Code;

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
                () -> config.handoffHmacKey("knobby-prod"));

        assertEquals(Code.MISSING_HMAC_KEY, ex.getCode());
        assertEquals("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", ex.getParameterName());
    }

    @Test
    void handoffHmacKey_malformedBase64_throwsMalformedBase64()
    {
        Map<String, String> env = new HashMap<>();
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", "not!valid!base64!");

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> configFor(env).handoffHmacKey("knobby-prod"));

        assertEquals(Code.MALFORMED_BASE64, ex.getCode());
    }

    @Test
    void handoffHmacKey_wrongLength_throwsWrongKeyLengthWithActualLength()
    {
        Map<String, String> env = new HashMap<>();
        // base64 of 8 zero bytes -> 8 != 32.
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", "AAAAAAAAAAA=");

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> configFor(env).handoffHmacKey("knobby-prod"));

        assertEquals(Code.WRONG_KEY_LENGTH, ex.getCode());
        assertTrue(ex.getMessage().contains("8"),
                "message should include the actual decoded length: " + ex.getMessage());
    }

    @Test
    void handoffHmacKey_validKey_returnsValue()
    {
        Map<String, String> env = new HashMap<>();
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", VALID_32B_KEY);

        assertEquals(VALID_32B_KEY, configFor(env).handoffHmacKey("knobby-prod"));
    }

    @Test
    void handoffHmacKey_realmNameNormalised_resolvesUppercaseUnderscored()
    {
        Map<String, String> env = new HashMap<>();
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_TEST", VALID_32B_KEY);

        assertEquals(VALID_32B_KEY, configFor(env).handoffHmacKey("knobby-test"));
    }

    @Test
    void handoffHmacKeyPrevious_unset_returnsNull()
    {
        assertNull(configFor(new HashMap<>()).handoffHmacKeyPrevious("knobby-prod"));
    }

    @Test
    void handoffHmacKeyPrevious_set_returnsValue()
    {
        Map<String, String> env = new HashMap<>();
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__KNOBBY_PROD", VALID_32B_KEY);

        assertEquals(VALID_32B_KEY, configFor(env).handoffHmacKeyPrevious("knobby-prod"));
    }

    @Test
    void handoffHmacKeyPrevious_setButMalformed_throwsMalformedBase64()
    {
        Map<String, String> env = new HashMap<>();
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__KNOBBY_PROD", "not!base64!");

        McpSpiConfigException ex = assertThrows(McpSpiConfigException.class,
                () -> configFor(env).handoffHmacKeyPrevious("knobby-prod"));

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
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_PROD", VALID_32B_KEY);
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_DEV", VALID_32B_KEY);
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY__KNOBBY_TEST", VALID_32B_KEY);
        env.put("UNRELATED_VAR", "ignore-me");
        // Previous-slot entries must NOT be reported as currently-configured realms.
        env.put("KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__KNOBBY_PROD", VALID_32B_KEY);

        assertEquals(Set.of("knobby-prod", "knobby-dev", "knobby-test"),
                configFor(env).realmsWithKeysConfigured());
    }

    @Test
    void normalise_realmWithHyphens_uppercasesAndReplacesHyphenWithUnderscore()
    {
        assertEquals("KNOBBY_PROD", McpSpiConfig.normalise("knobby-prod"));
        assertEquals("KNOBBY_DEV", McpSpiConfig.normalise("knobby-dev"));
        assertEquals("KNOBBY_TEST", McpSpiConfig.normalise("knobby-test"));
    }

    private static McpSpiConfig configFor(Map<String, String> env)
    {
        return new McpSpiConfig(env::get, () -> env);
    }
}
