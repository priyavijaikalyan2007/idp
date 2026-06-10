/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: dd323263-7294-4070-a219-9d9086dfb6a2
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.mapper;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.representations.AccessToken;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class McpScopeOverrideMapperTest
{
    @Mock
    private UserSessionModel userSession;

    @Mock
    private ProtocolMapperModel mappingModel;

    @Mock
    private KeycloakSession session;

    @Mock
    private ClientSessionContext clientSessionCtx;

    private McpScopeOverrideMapper mapper;
    private AccessToken token;

    @BeforeEach
    void setUp()
    {
        mapper = new McpScopeOverrideMapper();
        token = new AccessToken();
        token.setScope("openid profile");
    }

    // -------------------------------------------------- transform behaviour

    @Test
    void transformAccessToken_noteUnset_returnsTokenWithOriginalScope()
    {
        when(userSession.getNote(McpScopeOverrideMapper.SESSION_NOTE_SCOPES))
                .thenReturn(null);

        AccessToken result = mapper.transformAccessToken(
                token, mappingModel, session, userSession, clientSessionCtx);

        assertSame(token, result);
        assertEquals("openid profile", result.getScope(),
                "scope must be left unchanged when the session note is absent");
    }

    @Test
    void transformAccessToken_noteBlank_returnsTokenUnchanged()
    {
        when(userSession.getNote(McpScopeOverrideMapper.SESSION_NOTE_SCOPES))
                .thenReturn("   ");

        AccessToken result = mapper.transformAccessToken(
                token, mappingModel, session, userSession, clientSessionCtx);

        assertEquals("openid profile", result.getScope(),
                "blank note must not blank out the existing scope");
    }

    @Test
    void transformAccessToken_notePresent_overwritesScope()
    {
        when(userSession.getNote(McpScopeOverrideMapper.SESSION_NOTE_SCOPES))
                .thenReturn("yourapp:read yourapp:write");

        AccessToken result = mapper.transformAccessToken(
                token, mappingModel, session, userSession, clientSessionCtx);

        assertEquals("yourapp:read yourapp:write", result.getScope());
    }

    @Test
    void transformAccessToken_emptyOriginalScope_setsFromNote()
    {
        AccessToken empty = new AccessToken();
        assertNull(empty.getScope(), "precondition: fresh token has no scope");

        when(userSession.getNote(McpScopeOverrideMapper.SESSION_NOTE_SCOPES))
                .thenReturn("yourapp:read");

        AccessToken result = mapper.transformAccessToken(
                empty, mappingModel, session, userSession, clientSessionCtx);

        assertEquals("yourapp:read", result.getScope());
    }

    // ------------------------------------------------------- factory metadata

    @Test
    void getId_returnsStableProviderId()
    {
        assertEquals("yourapp-mcp-scope-override", mapper.getId());
        assertEquals(McpScopeOverrideMapper.PROVIDER_ID, mapper.getId());
    }

    @Test
    void getDisplayType_isAdminConsoleLabel()
    {
        assertEquals("YourApp MCP Scope Override", mapper.getDisplayType());
    }

    @Test
    void getDisplayCategory_isTokenMapper()
    {
        assertEquals(AbstractOIDCProtocolMapper.TOKEN_MAPPER_CATEGORY,
                mapper.getDisplayCategory());
    }

    @Test
    void getHelpText_describesIntentAndNoConfig()
    {
        String help = mapper.getHelpText();
        assertNotNull(help);
        assertTrue(help.toLowerCase().contains("scope"));
        assertTrue(help.contains(McpScopeOverrideMapper.SESSION_NOTE_SCOPES));
    }

    @Test
    void getConfigProperties_isEmpty()
    {
        assertEquals(0, mapper.getConfigProperties().size());
    }

    @Test
    void getProtocol_isOidc()
    {
        assertEquals("openid-connect", mapper.getProtocol());
    }
}
