/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: bdc2e693-dc96-4576-aac3-46278b860929
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.authenticator;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.function.Supplier;

import jakarta.ws.rs.core.Response;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.models.AuthenticatorConfigModel;
import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientScopeModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

import io.yourapp.keycloak.mcp.config.McpSpiConfig;
import io.yourapp.keycloak.mcp.jwt.HandoffTokenSigner;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class McpTenantPickerAuthenticatorTest
{
    private static final String VALID_32B_KEY =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    private static final long T0 =
            Instant.parse("2026-06-08T12:00:00Z").getEpochSecond();

    @Mock private AuthenticationFlowContext context;
    @Mock private RealmModel realm;
    @Mock private UserModel user;
    @Mock private AuthenticationSessionModel authSession;
    @Mock private RootAuthenticationSessionModel rootAuthSession;
    @Mock private ClientModel client;
    @Mock private ClientScopeModel mcpDefaultScope;
    @Mock private AuthenticatorConfigModel authConfigModel;
    @Mock private KeycloakSession session;

    private HandoffTokenSigner signer;
    private McpTenantPickerAuthenticator authenticator;

    @BeforeEach
    void setUp()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", VALID_32B_KEY);
        signer = new HandoffTokenSigner(new McpSpiConfig(env::get, () -> env));

        Supplier<String> fixedNonce = () -> "deadbeefcafebabe1234567890abcdef";
        Supplier<String> fixedJti = () -> "fixed-jti-1234";
        Clock fixedClock = Clock.fixed(Instant.ofEpochSecond(T0), ZoneOffset.UTC);
        authenticator = new McpTenantPickerAuthenticator(signer, fixedClock, fixedNonce, fixedJti);

        // Common stubs for the happy path; tests may override.
        when(context.getRealm()).thenReturn(realm);
        when(context.getUser()).thenReturn(user);
        when(context.getAuthenticationSession()).thenReturn(authSession);
        when(context.getAuthenticatorConfig()).thenReturn(authConfigModel);
        when(realm.getName()).thenReturn("yourapp-prod");
        when(user.getId()).thenReturn("user-sub-123");
        when(authSession.getClient()).thenReturn(client);
        when(authSession.getParentSession()).thenReturn(rootAuthSession);
        when(authSession.getTabId()).thenReturn("tab-1");
        when(authSession.getClientScopes())
                .thenReturn(Set.of("openid", "yourapp:read", "yourapp:write"));
        when(authSession.getClientNote(OIDCLoginProtocol.STATE_PARAM))
                .thenReturn("oauth-state-xyz");
        when(client.getClientId()).thenReturn("mcp-client-abc");
        when(rootAuthSession.getId()).thenReturn("root-auth-1");

        // By default the happy-path client IS an MCP client: it carries the
        // mcp-default client scope as a default scope. Tests exercising the
        // short-circuit override these stubs.
        when(client.getClientScopes(true))
                .thenReturn(Map.of(McpTenantPickerAuthenticator.MCP_CLIENT_SCOPE, mcpDefaultScope));
        when(client.getClientScopes(false)).thenReturn(Map.of());

        Map<String, String> webHostConfig = new HashMap<>();
        webHostConfig.put(McpTenantPickerAuthenticator.CONFIG_KEY_WEB_HOST,
                "prod.yourapp.com");
        when(authConfigModel.getConfig()).thenReturn(webHostConfig);
    }

    // -------------------------------------------------------------- happy path

    @Test
    void authenticate_validInputs_emitsRedirectAndSuspends()
    {
        authenticator.authenticate(context);

        Response response = captureChallengeResponse();
        assertEquals(Response.Status.SEE_OTHER.getStatusCode(), response.getStatus());
        URI location = response.getLocation();
        assertNotNull(location, "Location header must be set");
        assertEquals("prod.yourapp.com", location.getHost());
        assertEquals("/mcp/consent", location.getPath());
        assertEquals("https", location.getScheme());
    }

    @Test
    void authenticate_validInputs_redirectQueryCarriesUrlEncodedJwt()
    {
        authenticator.authenticate(context);

        Response response = captureChallengeResponse();
        URI location = response.getLocation();
        String query = location.getRawQuery();
        assertTrue(query.startsWith("token="), "expected token= query: " + query);

        String encoded = query.substring("token=".length());
        String decoded = URLDecoder.decode(encoded, StandardCharsets.UTF_8);
        // A JWS has three base64url segments joined by '.'.
        assertEquals(3, decoded.split("\\.").length,
                "decoded token must be a 3-part JWS: " + decoded);
    }

    // ------------------------------------------------ resume after callback (ERRATA-004)

    @Test
    void authenticate_pickerCompletedNoteSet_finishesWithoutChallenge()
    {
        // The mcp-picker-callback recorded the consent and re-entered the flow;
        // authenticate() must FINISH the step, not issue a fresh picker-request
        // (which would 303 back to /mcp/consent forever).
        when(authSession.getAuthNote(
                McpTenantPickerAuthenticator.AUTH_NOTE_PICKER_COMPLETED))
                .thenReturn("true");

        authenticator.authenticate(context);

        verify(context).success();
        verify(context, never())
                .challenge(org.mockito.ArgumentMatchers.any(Response.class));
        verify(context, never()).failure(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void authenticate_pickerCompletedNoteAbsent_stillChallenges()
    {
        // Sanity: without the resume note (the first, pre-consent pass), the
        // MCP client is challenged as usual — the guard must not swallow it.
        when(authSession.getAuthNote(
                McpTenantPickerAuthenticator.AUTH_NOTE_PICKER_COMPLETED))
                .thenReturn(null);

        authenticator.authenticate(context);

        verify(context, never()).success();
        Response response = captureChallengeResponse();
        assertEquals(Response.Status.SEE_OTHER.getStatusCode(), response.getStatus());
    }

    // ------------------------------------------- short-circuit: non-MCP client

    @Test
    void authenticate_nonMcpClient_shortCircuitsWithSuccess()
    {
        // Client carries neither a default nor an optional mcp-default scope.
        when(client.getClientScopes(true)).thenReturn(Map.of());
        when(client.getClientScopes(false)).thenReturn(Map.of());

        authenticator.authenticate(context);

        verify(context).success();
    }

    @Test
    void authenticate_nonMcpClient_neverChallenges()
    {
        when(client.getClientScopes(true)).thenReturn(Map.of());
        when(client.getClientScopes(false)).thenReturn(Map.of());

        authenticator.authenticate(context);

        verify(context, never()).challenge(org.mockito.ArgumentMatchers.any(Response.class));
    }

    @Test
    void authenticate_nonMcpClient_neverFailsFlow()
    {
        when(client.getClientScopes(true)).thenReturn(Map.of());
        when(client.getClientScopes(false)).thenReturn(Map.of());

        authenticator.authenticate(context);

        verify(context, never()).failure(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void authenticate_mcpScopeAsOptional_proceedsToChallenge()
    {
        // Not a default scope, but present as an optional scope — still MCP.
        when(client.getClientScopes(true)).thenReturn(Map.of());
        when(client.getClientScopes(false))
                .thenReturn(Map.of(McpTenantPickerAuthenticator.MCP_CLIENT_SCOPE, mcpDefaultScope));

        authenticator.authenticate(context);

        Response response = captureChallengeResponse();
        assertEquals(Response.Status.SEE_OTHER.getStatusCode(), response.getStatus());
    }

    @Test
    void authenticate_mcpScopeAsDefault_doesNotShortCircuit()
    {
        // setUp() already makes the client an MCP client via a default scope.
        authenticator.authenticate(context);

        verify(context, never()).success();
        captureChallengeResponse();
    }

    @Test
    void authenticate_mcpAttributeSet_proceedsEvenWithoutScope()
    {
        // The yourapp.mcp attribute is the preferred signal (§5.8): a client
        // carrying it is MCP even if it has no mcp-default scope.
        when(client.getAttribute(McpTenantPickerAuthenticator.MCP_CLIENT_ATTRIBUTE))
                .thenReturn(McpTenantPickerAuthenticator.MCP_CLIENT_ATTRIBUTE_VALUE);
        when(client.getClientScopes(true)).thenReturn(Map.of());
        when(client.getClientScopes(false)).thenReturn(Map.of());

        authenticator.authenticate(context);

        verify(context, never()).success();
        Response response = captureChallengeResponse();
        assertEquals(Response.Status.SEE_OTHER.getStatusCode(), response.getStatus());
    }

    // ------------------------------------------------------- failure: no user

    @Test
    void authenticate_userNull_failsFlowWithInternalError()
    {
        when(context.getUser()).thenReturn(null);

        authenticator.authenticate(context);

        verify(context).failure(eq(AuthenticationFlowError.INTERNAL_ERROR));
        verify(context, never()).challenge(org.mockito.ArgumentMatchers.any(Response.class));
    }

    // -------------------------------------------- failure: missing yourapp.web.host

    @Test
    void authenticate_authenticatorConfigNull_failsFlow()
    {
        when(context.getAuthenticatorConfig()).thenReturn(null);

        authenticator.authenticate(context);

        verify(context).failure(eq(AuthenticationFlowError.INTERNAL_ERROR));
    }

    @Test
    void authenticate_webHostConfigBlank_failsFlow()
    {
        Map<String, String> cfg = new HashMap<>();
        cfg.put(McpTenantPickerAuthenticator.CONFIG_KEY_WEB_HOST, "   ");
        when(authConfigModel.getConfig()).thenReturn(cfg);

        authenticator.authenticate(context);

        verify(context).failure(eq(AuthenticationFlowError.INTERNAL_ERROR));
    }

    // ----------------------------------------------- failure: HMAC key not configured

    @Test
    void authenticate_hmacKeyMissingForRealm_failsFlow()
    {
        when(realm.getName()).thenReturn("yourapp-dev"); // no env var for this realm

        authenticator.authenticate(context);

        verify(context).failure(eq(AuthenticationFlowError.INTERNAL_ERROR));
        verify(context, never()).challenge(org.mockito.ArgumentMatchers.any(Response.class));
    }

    // ----------------------------------------------- failure: action() called

    @Test
    void action_anyCall_failsFlow()
    {
        authenticator.action(context);
        verify(context).failure(eq(AuthenticationFlowError.INTERNAL_ERROR));
    }

    // -------------------------------------------------- Authenticator trivia

    @Test
    void requiresUser_isTrue()
    {
        assertTrue(authenticator.requiresUser());
    }

    @Test
    void configuredFor_isTrue()
    {
        assertTrue(authenticator.configuredFor(session, realm, user));
    }

    @Test
    void close_doesNotThrow()
    {
        authenticator.close();
    }

    @Test
    void setRequiredActions_doesNotThrow()
    {
        authenticator.setRequiredActions(session, realm, user);
    }

    // ------------------------------------------------- oauth_state may be null

    @Test
    void authenticate_oauthStateAbsent_stillSuspendsSuccessfully()
    {
        when(authSession.getClientNote(OIDCLoginProtocol.STATE_PARAM)).thenReturn(null);

        authenticator.authenticate(context);

        Response response = captureChallengeResponse();
        // The token still builds (state is optional); a 303 is still emitted.
        assertEquals(Response.Status.SEE_OTHER.getStatusCode(), response.getStatus());
    }

    // ------------------------------------------------ test scopes are deterministic

    @Test
    void authenticate_clientScopesEmpty_handledGracefully()
    {
        when(authSession.getClientScopes()).thenReturn(Set.of());

        authenticator.authenticate(context);

        // Should still emit a redirect (the request token tolerates empty scopes).
        Response response = captureChallengeResponse();
        assertNotNull(response.getLocation());
    }

    // --------------------------------------------------------- defensive sanity

    @Test
    void authenticate_userNullPath_neverInvokesSignerOrChallenge()
    {
        when(context.getUser()).thenReturn(null);

        authenticator.authenticate(context);

        verify(context, never()).challenge(org.mockito.ArgumentMatchers.any(Response.class));
        verify(user, never()).getId();
    }

    // -------------------------------------------------------------- helpers

    private Response captureChallengeResponse()
    {
        ArgumentCaptor<Response> captor = ArgumentCaptor.forClass(Response.class);
        verify(context).challenge(captor.capture());
        return captor.getValue();
    }
}
