/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 045ab29f-d1e2-4160-b444-0316f167f2f3
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.resource;

import java.net.URI;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

import jakarta.ws.rs.core.Response;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientScopeModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.services.managers.AuthenticationSessionManager;
import org.keycloak.sessions.AuthenticationSessionModel;

import io.yourapp.keycloak.mcp.authenticator.McpTenantPickerAuthenticator;
import io.yourapp.keycloak.mcp.config.McpSpiConfig;
import io.yourapp.keycloak.mcp.jwt.HandoffTokenSigner;
import io.yourapp.keycloak.mcp.jwt.HandoffTokenValidator;
import io.yourapp.keycloak.mcp.jwt.PickerResultToken;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class McpPickerCallbackResourceProviderTest
{
    private static final String VALID_32B_KEY =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    private static final long T0 =
            Instant.parse("2026-06-08T12:00:00Z").getEpochSecond();
    private static final URI MOCK_RESUME_URI = URI.create("https://test/resume");

    @Mock private KeycloakSession keycloakSession;
    @Mock private KeycloakContext keycloakContext;
    @Mock private RealmModel realm;
    @Mock private ClientModel client;
    @Mock private UserModel currentUser;
    @Mock private AuthenticationSessionModel authSession;
    @Mock private AuthenticationSessionManager sessionManager;
    @Mock private ClientScopeModel scopeMock;
    @Mock private SingleUseObjectProvider singleUseObjects;

    private HandoffTokenSigner signer;
    private HandoffTokenValidator validator;
    private McpPickerCallbackResourceProvider provider;

    @BeforeEach
    void setUp()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", VALID_32B_KEY);
        McpSpiConfig config = new McpSpiConfig(env::get, () -> env);
        signer = new HandoffTokenSigner(config);
        Clock clock = Clock.fixed(Instant.ofEpochSecond(T0), ZoneOffset.UTC);
        validator = new HandoffTokenValidator(config, clock);

        when(keycloakSession.getContext()).thenReturn(keycloakContext);
        when(keycloakContext.getRealm()).thenReturn(realm);
        when(realm.getName()).thenReturn("yourapp-prod");

        // RT-010: replay defense is the provider's ReplayGuard over
        // session.singleUseObjects(). Default: firstUse succeeds (jti unseen).
        when(keycloakSession.singleUseObjects()).thenReturn(singleUseObjects);
        when(singleUseObjects.putIfAbsent(anyString(), anyLong())).thenReturn(true);

        // Defaults so happy-path tests satisfy the RT-008/009 checks. The valid
        // result echoes picker_request_jti=req-jti-1, oauth_state=oauth-state-xyz,
        // and grants yourapp:read — all consistent with these stubs. Individual
        // tests override to exercise the mismatch/rejection paths. (LENIENT.)
        when(authSession.getAuthNote(
                McpTenantPickerAuthenticator.AUTH_NOTE_PICKER_REQUEST_JTI))
                .thenReturn("req-jti-1");
        when(authSession.getClientNote(OIDCLoginProtocol.STATE_PARAM))
                .thenReturn("oauth-state-xyz");
        Map<String, ClientScopeModel> assignedScopes = new HashMap<>();
        for (String s : List.of("mcp-default", "yourapp:read", "yourapp:comment",
                "yourapp:curate", "yourapp:write", "yourapp:share", "yourapp:admin"))
        {
            assignedScopes.put(s, scopeMock);
        }
        when(client.getClientScopes(true)).thenReturn(assignedScopes);
        when(client.getClientScopes(false)).thenReturn(Map.of());

        Function<KeycloakSession, AuthenticationSessionManager> managerFactory =
                s -> sessionManager;
        McpPickerCallbackResourceProvider.ResumeUrlBuilder resumeUrlBuilder =
                (s, r, a) -> MOCK_RESUME_URI;

        provider = new McpPickerCallbackResourceProvider(keycloakSession, validator,
                managerFactory, resumeUrlBuilder);
    }

    // -------------------------------------------------- early-return failures

    @Test
    void handleCallback_missingPickerResult_returns400MissingToken()
    {
        Response response = provider.handleCallback(null);

        assertEquals(400, response.getStatus());
        assertEquals("missing_token", error(response));
        verify(sessionManager, never()).getCurrentAuthenticationSession(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void handleCallback_blankPickerResult_returns400MissingToken()
    {
        Response response = provider.handleCallback("   ");

        assertEquals(400, response.getStatus());
        assertEquals("missing_token", error(response));
    }

    // ----------------------------------------- HandoffValidationException mapping

    @Test
    void handleCallback_malformedJwt_returns400InvalidHandoffMalformed()
    {
        Response response = provider.handleCallback("not-a-jwt");

        assertEquals(400, response.getStatus());
        assertEquals("invalid_handoff", error(response));
        assertEquals("MALFORMED", description(response));
    }

    @Test
    void handleCallback_tamperedSignature_returns400InvalidHandoffBadSignature()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        // Flip first char of the signature segment — always changes a
        // meaningful bit (see HandoffTokenValidatorTest for the explanation).
        String[] parts = jwt.split("\\.");
        char first = parts[2].charAt(0);
        char flipped = (first == 'A') ? 'B' : 'A';
        String tampered = parts[0] + "." + parts[1] + "."
                + flipped + parts[2].substring(1);

        Response response = provider.handleCallback(tampered);

        assertEquals(400, response.getStatus());
        assertEquals("invalid_handoff", error(response));
        assertEquals("BAD_SIGNATURE", description(response));
    }

    @Test
    void handleCallback_replay_returns400InvalidHandoffReplay()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        // The single-use store accepts the jti once, then reports it present.
        when(singleUseObjects.putIfAbsent(anyString(), anyLong())).thenReturn(true, false);

        // First call consumes the jti via session.singleUseObjects().
        provider.handleCallback(jwt);

        // Second call with the same token must be rejected as a replay.
        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("invalid_handoff", error(response));
        assertEquals("REPLAY", description(response));
    }

    // ------------------------------------------- McpSpiConfigException mapping

    @Test
    void handleCallback_realmHasNoHmacKey_returns400RealmMisconfigured()
    {
        // Stand up a fresh validator backed by an empty env so config throws on lookup.
        Map<String, String> emptyEnv = new HashMap<>();
        McpSpiConfig emptyConfig = new McpSpiConfig(emptyEnv::get, () -> emptyEnv);
        HandoffTokenValidator badValidator = new HandoffTokenValidator(emptyConfig,
                Clock.fixed(Instant.ofEpochSecond(T0), ZoneOffset.UTC));
        McpPickerCallbackResourceProvider badProvider =
                new McpPickerCallbackResourceProvider(keycloakSession, badValidator,
                        s -> sessionManager, (s, r, a) -> MOCK_RESUME_URI);

        // The validator throws McpSpiConfigException MISSING_HMAC_KEY on a token
        // for any realm, regardless of whether the token itself is structurally
        // valid — the env-based key resolution fails first.
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");

        Response response = badProvider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("realm_misconfigured", error(response));
        assertEquals("MISSING_HMAC_KEY", description(response));
    }

    // --------------------------------------------- client / session lookup paths

    @Test
    void handleCallback_clientIdNotFound_returns400ClientNotFound()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(null);

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("client_not_found", error(response));
    }

    @Test
    void handleCallback_missingCorrelationClaims_returns400MissingCorrelation()
    {
        // Reproduces the production bug (ERRATA-003): the app's picker-result
        // omits the kc_* correlation claims it must echo from the picker-request.
        // Signed as a raw claim map (the app's actual claim set) so the missing
        // fields deserialize to null — the Builder would otherwise require them.
        Map<String, Object> appClaims = new HashMap<>();
        appClaims.put("iss", "yourapp-web-mcp-consent");
        appClaims.put("aud", "keycloak-mcp-spi");
        appClaims.put("picker_request_jti", "req-jti-1");
        appClaims.put("user_sub_echo", "user-sub-123");
        appClaims.put("chosen_tenant_id", "tenant-uuid-1");
        appClaims.put("granted_scopes", List.of("yourapp:read"));
        appClaims.put("oauth_state", "oauth-state-xyz");
        appClaims.put("nonce", "nonce-3");
        appClaims.put("jti", "res-jti-missing-corr");
        appClaims.put("iat", T0 - 10);
        appClaims.put("exp", T0 + 60);
        String jwt = signer.sign(appClaims, "yourapp-prod");

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("missing_correlation", error(response));
        // Must not attempt a client lookup with a null id.
        verify(realm, never()).getClientByClientId(
                org.mockito.ArgumentMatchers.any());
    }

    @Test
    void handleCallback_authSessionNotFoundAnywhere_returns400SessionNotFound()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(null);
        when(sessionManager.getAuthenticationSessionByIdAndClient(
                realm, "root-auth-1", client, "tab-1")).thenReturn(null);

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("session_not_found", error(response));
    }

    @Test
    void handleCallback_authSessionFoundViaCookie_continuesWithCookieResult()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");

        Response response = provider.handleCallback(jwt);

        // Happy path: 303 to the mocked resume URI.
        assertEquals(303, response.getStatus());
        assertEquals(MOCK_RESUME_URI, response.getLocation());
        // Fallback lookup must NOT have been invoked since cookie path succeeded.
        verify(sessionManager, never()).getAuthenticationSessionByIdAndClient(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void handleCallback_cookieAbsent_fallsBackToIdLookup()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        // Cookie-based lookup returns null; fallback returns the session.
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(null);
        when(sessionManager.getAuthenticationSessionByIdAndClient(
                realm, "root-auth-1", client, "tab-1")).thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");

        Response response = provider.handleCallback(jwt);

        assertEquals(303, response.getStatus());
        verify(sessionManager).getAuthenticationSessionByIdAndClient(
                eq(realm), eq("root-auth-1"), eq(client), eq("tab-1"));
    }

    // ----------------------------------------------- user-sub-echo cross-check

    @Test
    void handleCallback_userMismatch_returns400UserMismatch()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        // Session's user is somebody else than the token claims.
        when(currentUser.getId()).thenReturn("different-user");

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("user_mismatch", error(response));
    }

    @Test
    void handleCallback_authenticatedUserNull_returns400UserMismatch()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(null);

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("user_mismatch", error(response));
    }

    // ------------------------------------------- happy-path note writing + redirect

    @Test
    void handleCallback_happyPath_writesSessionNotesAndRedirects()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");

        Response response = provider.handleCallback(jwt);

        assertEquals(303, response.getStatus());
        assertEquals(MOCK_RESUME_URI, response.getLocation());
        verify(authSession).setUserSessionNote("yourapp_tenant_id", "tenant-uuid-1");
        verify(authSession).setUserSessionNote("yourapp_scopes", "yourapp:read");
    }

    @Test
    void handleCallback_happyPath_marksPickerCompletedForResume()
    {
        // ERRATA-004: the callback must set the resume signal the authenticator
        // reads on re-entry, else authenticate() re-challenges and loops.
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");

        provider.handleCallback(jwt);

        verify(authSession).setAuthNote(
                McpTenantPickerAuthenticator.AUTH_NOTE_PICKER_COMPLETED, "true");
    }

    @Test
    void handleCallback_emptyGrantedScopes_writesEmptyScopeNote()
    {
        String jwt = signer.sign(
                validResultBuilder().grantedScopes(List.of()).build(),
                "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");

        Response response = provider.handleCallback(jwt);

        assertEquals(303, response.getStatus());
        verify(authSession).setUserSessionNote("yourapp_scopes", "");
    }

    @Test
    void handleCallback_multipleGrantedScopes_joinedWithSpaces()
    {
        String jwt = signer.sign(
                validResultBuilder()
                        .grantedScopes(List.of("yourapp:read", "yourapp:write"))
                        .build(),
                "yourapp-prod");
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");

        Response response = provider.handleCallback(jwt);

        assertEquals(303, response.getStatus());
        verify(authSession).setUserSessionNote("yourapp_scopes", "yourapp:read yourapp:write");
    }

    // ------------------------------------------------- RealmResourceProvider api

    @Test
    void getResource_returnsThisInstance()
    {
        assertTrue(provider.getResource() instanceof McpPickerCallbackResourceProvider);
        assertEquals(provider, provider.getResource());
    }

    @Test
    void close_doesNotThrow()
    {
        provider.close();
    }

    // ------------------------------------------------------------------ helpers

    private static PickerResultToken.Builder validResultBuilder()
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
                .iat(T0 - 10)
                .exp(T0 + 60);
    }

    // --------------------------------------------- RT-008/009 hardening tests

    /** Stubs a recoverable auth session with the echoed user — the common prefix. */
    private void stubValidSession()
    {
        when(realm.getClientByClientId("mcp-client-abc")).thenReturn(client);
        when(sessionManager.getCurrentAuthenticationSession(realm, client, "tab-1"))
                .thenReturn(authSession);
        when(authSession.getAuthenticatedUser()).thenReturn(currentUser);
        when(currentUser.getId()).thenReturn("user-sub-123");
    }

    @Test
    void handleCallback_requestJtiMismatch_returns400RequestMismatch()
    {
        // RT-008: the auth session remembers a DIFFERENT request jti than the one
        // the result echoes — a result signed for another request must be refused.
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        stubValidSession();
        when(authSession.getAuthNote(
                McpTenantPickerAuthenticator.AUTH_NOTE_PICKER_REQUEST_JTI))
                .thenReturn("a-different-request-jti");

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("request_mismatch", error(response));
        verify(authSession, never()).setUserSessionNote(eq("yourapp_scopes"), org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void handleCallback_oauthStateMismatch_returns400StateMismatch()
    {
        String jwt = signer.sign(validResultBuilder().build(), "yourapp-prod");
        stubValidSession();
        when(authSession.getClientNote(OIDCLoginProtocol.STATE_PARAM))
                .thenReturn("a-different-state");

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("state_mismatch", error(response));
    }

    @Test
    void handleCallback_malformedTenantId_returns400InvalidTenant()
    {
        String jwt = signer.sign(
                validResultBuilder().chosenTenantId("bad tenant!").build(), "yourapp-prod");
        stubValidSession();

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("invalid_tenant", error(response));
    }

    @Test
    void handleCallback_grantedScopeNotAssignedToClient_returns400InvalidScopes()
    {
        // RT-009: the result grants a scope the client is NOT assigned — a consent
        // service bug must not mint arbitrary/elevated scopes into the token.
        String jwt = signer.sign(
                validResultBuilder().grantedScopes(List.of("yourapp:read", "realm-admin"))
                        .build(), "yourapp-prod");
        stubValidSession();

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("invalid_scopes", error(response));
        verify(authSession, never()).setUserSessionNote(eq("yourapp_scopes"), org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void handleCallback_duplicateGrantedScopes_returns400InvalidScopes()
    {
        String jwt = signer.sign(
                validResultBuilder().grantedScopes(List.of("yourapp:read", "yourapp:read"))
                        .build(), "yourapp-prod");
        stubValidSession();

        Response response = provider.handleCallback(jwt);

        assertEquals(400, response.getStatus());
        assertEquals("invalid_scopes", error(response));
    }

    @SuppressWarnings("unchecked")
    private static String error(Response response)
    {
        Map<String, String> body = (Map<String, String>) response.getEntity();
        return body.get("error");
    }

    @SuppressWarnings("unchecked")
    private static String description(Response response)
    {
        Map<String, String> body = (Map<String, String>) response.getEntity();
        return body.get("error_description");
    }
}
