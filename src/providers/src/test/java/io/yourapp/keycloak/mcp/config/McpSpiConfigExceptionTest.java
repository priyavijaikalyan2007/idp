/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 149b7df6-6dc2-4ad6-b98a-8793410a127d
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.config;

import org.junit.jupiter.api.Test;

import io.yourapp.keycloak.mcp.config.McpSpiConfigException.Code;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class McpSpiConfigExceptionTest
{
    @Test
    void getCode_andGetParameterName_returnConstructorValues()
    {
        McpSpiConfigException ex = new McpSpiConfigException(
                Code.MISSING_HMAC_KEY, "YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD");

        assertEquals(Code.MISSING_HMAC_KEY, ex.getCode());
        assertEquals("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", ex.getParameterName());
        assertTrue(ex.getMessage().contains("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD"));
    }

    @Test
    void wrongKeyLength_messageIncludesActualLength()
    {
        McpSpiConfigException ex = new McpSpiConfigException(
                Code.WRONG_KEY_LENGTH, "YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", 16);

        assertEquals(Code.WRONG_KEY_LENGTH, ex.getCode());
        assertTrue(ex.getMessage().contains("16"));
        assertTrue(ex.getMessage().contains("32"));
    }

    @Test
    void malformedBase64_hasDescriptiveMessage()
    {
        McpSpiConfigException ex = new McpSpiConfigException(
                Code.MALFORMED_BASE64, "YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_DEV");

        assertEquals(Code.MALFORMED_BASE64, ex.getCode());
        assertTrue(ex.getMessage().contains("base64"));
    }

    @Test
    void missingWebHost_namesTheConfigProperty()
    {
        McpSpiConfigException ex = new McpSpiConfigException(
                Code.MISSING_WEB_HOST, "yourapp.web.host");

        assertEquals(Code.MISSING_WEB_HOST, ex.getCode());
        assertTrue(ex.getMessage().contains("yourapp.web.host"));
    }
}
