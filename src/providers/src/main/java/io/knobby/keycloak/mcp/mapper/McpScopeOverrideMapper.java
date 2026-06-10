/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 014c26bb-109c-407e-8acf-736d571901da
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpScopeOverrideMapper
 * 📜 PURPOSE: OIDC protocol mapper that overrides the access-token `scope`
 *             claim with the space-separated value of the user-session note
 *             `knobby_scopes` (written by McpPickerCallbackResourceProvider
 *             once Knobby web's consent wizard returns).
 * 🔗 RELATES: [[McpPickerCallbackResourceProvider]],
 *             [[McpDefaultClientScope]]
 * ⚡ FLOW: [Keycloak token issuance] -> [this.transformAccessToken]
 *         -> [AccessToken.setScope]
 * 🛡️ SECURITY: Replaces scope wholesale with the user's wizard choice — the
 *              MCP server downstream relies on this claim for authorization.
 *              See ADR-004.
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.mapper;

import java.util.List;

import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;

/**
 * Mapper + factory in one class — Keycloak's OIDC mapper SPI conflates them
 * (see {@code AbstractOIDCProtocolMapper.create} which returns {@code this}).
 *
 * <p>Implements only {@link OIDCAccessTokenMapper}: the OIDC {@code scope}
 * claim is an access-token field, not an ID-token or userinfo field, so the
 * marker interfaces for those two are intentionally omitted. If a future
 * requirement extends the mapper to those token types, add the interfaces
 * and override the corresponding {@code transform...} methods on the abstract
 * base.
 *
 * <p>See {@code keycloak.spi.mcp.md} §5.5 and ADR-004 (custom mapper over
 * Script Mapper).
 */
public final class McpScopeOverrideMapper
        extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper
{
    /** Provider id surfaced to admins; matches realm-config references. */
    public static final String PROVIDER_ID = "knobby-mcp-scope-override";

    /** Session-note key the picker-callback resource provider writes to. */
    static final String SESSION_NOTE_SCOPES = "knobby_scopes";

    private static final String DISPLAY_TYPE = "Knobby MCP Scope Override";

    private static final String HELP_TEXT =
            "Overrides the access-token 'scope' claim with the space-separated "
                    + "value of user-session note '" + SESSION_NOTE_SCOPES
                    + "'. Attached to the mcp-default Client Scope. No per-instance "
                    + "configuration — the note is written by the MCP picker callback "
                    + "after Knobby web's consent wizard completes.";

    @Override
    public String getId()
    {
        return PROVIDER_ID;
    }

    @Override
    public String getDisplayType()
    {
        return DISPLAY_TYPE;
    }

    @Override
    public String getDisplayCategory()
    {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getHelpText()
    {
        return HELP_TEXT;
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties()
    {
        return List.of();
    }

    @Override
    public AccessToken transformAccessToken(
            AccessToken token,
            ProtocolMapperModel mappingModel,
            KeycloakSession session,
            UserSessionModel userSession,
            ClientSessionContext clientSessionCtx)
    {
        String scopes = userSession.getNote(SESSION_NOTE_SCOPES);
        if (scopes == null || scopes.isBlank())
        {
            return token;
        }
        token.setScope(scopes);
        return token;
    }
}
