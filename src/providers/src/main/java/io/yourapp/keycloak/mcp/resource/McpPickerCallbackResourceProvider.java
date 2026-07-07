/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: e310b180-6e2d-42e4-ada7-5743f237db40
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpPickerCallbackResourceProvider
 * 📜 PURPOSE: JAX-RS endpoint at /realms/{realm}/mcp-picker-callback. Validates
 *             the picker-result JWT returned by YourApp web, re-finds the
 *             suspended auth session via AUTH_SESSION_ID cookie (with auth-
 *             session-id fallback from the JWT), writes the tenant + scopes
 *             user-session notes, and 302-redirects back into the suspended
 *             flow via AuthenticationFlowURLHelper.getLastExecutionUrl so
 *             Keycloak's flow engine resumes from the CHALLENGED authenticator
 *             execution.
 * 🔗 RELATES: [[HandoffTokenValidator]], [[McpTenantPickerAuthenticator]],
 *             [[McpScopeOverrideMapper]]
 * ⚡ FLOW: [YourApp web 302] -> [this.handleCallback]
 *         -> [AuthenticationSessionManager.getCurrentAuthenticationSession]
 *         -> [AuthenticationFlowURLHelper.getLastExecutionUrl]
 *         -> [Keycloak flow engine resumes]
 * 🛡️ SECURITY: HMAC signature + jti replay (validator) + user_sub_echo cross
 *              check + per-realm key isolation. kc_* correlation fields are
 *              HMAC-signed (not query-param tamperable). The app MUST echo the
 *              kc_client_id / kc_tab_id / auth_session_id claims from the
 *              picker-request into the picker-result (web spec §3.3 / ERRATA-003);
 *              their absence is reported as `missing_correlation`, distinct from
 *              a genuine `client_not_found`.
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.resource;

import java.net.URI;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import org.jboss.logging.Logger;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.managers.AuthenticationSessionManager;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.util.AuthenticationFlowURLHelper;
import org.keycloak.sessions.AuthenticationSessionModel;

import io.yourapp.keycloak.mcp.config.McpSpiConfigException;
import io.yourapp.keycloak.mcp.jwt.HandoffTokenValidator;
import io.yourapp.keycloak.mcp.jwt.HandoffValidationException;
import io.yourapp.keycloak.mcp.jwt.PickerResultToken;

/**
 * Combined provider + JAX-RS resource. The {@link #getResource()} method
 * returns {@code this}; JAX-RS reads the {@code @GET}/{@code @Path}
 * annotations off this same class.
 *
 * <p>Two function-injection points (session-manager factory + resume-URL
 * builder) let unit tests exercise the failure and happy paths without
 * standing up a real Keycloak runtime. Production wires the real
 * implementations.
 *
 * <p>See {@code keycloak.spi.mcp.md} §5.3 and the suspend / resume design in
 * {@code keycloak.spi.mcp.status.md} §3.5.
 */
public final class McpPickerCallbackResourceProvider implements RealmResourceProvider
{
    private static final Logger log =
            Logger.getLogger(McpPickerCallbackResourceProvider.class);

    /** User-session note set on the auth session for Keycloak's `tenant` claim mapper. */
    static final String SESSION_NOTE_TENANT_ID = "yourapp_tenant_id";

    /** User-session note read by {@code McpScopeOverrideMapper} to set `scope`. */
    static final String SESSION_NOTE_SCOPES = "yourapp_scopes";

    /** Builds the resume URL for the suspended flow (test seam). */
    @FunctionalInterface
    interface ResumeUrlBuilder
    {
        URI build(KeycloakSession session, RealmModel realm,
                AuthenticationSessionModel authSession);
    }

    private final KeycloakSession session;
    private final HandoffTokenValidator validator;
    private final Function<KeycloakSession, AuthenticationSessionManager> managerFactory;
    private final ResumeUrlBuilder resumeUrlBuilder;

    /** Production constructor: real session manager and real flow URL helper. */
    public McpPickerCallbackResourceProvider(
            KeycloakSession session, HandoffTokenValidator validator)
    {
        this(session, validator,
                AuthenticationSessionManager::new,
                McpPickerCallbackResourceProvider::defaultResumeUrl);
    }

    /** Test seam: inject custom session-manager factory and resume-URL builder. */
    McpPickerCallbackResourceProvider(
            KeycloakSession session,
            HandoffTokenValidator validator,
            Function<KeycloakSession, AuthenticationSessionManager> managerFactory,
            ResumeUrlBuilder resumeUrlBuilder)
    {
        this.session = session;
        this.validator = validator;
        this.managerFactory = managerFactory;
        this.resumeUrlBuilder = resumeUrlBuilder;
    }

    @Override
    public Object getResource()
    {
        return this;
    }

    @Override
    public void close()
    {
        // No-op.
    }

    /**
     * Callback entry point. JAX-RS dispatches GET on
     * {@code /realms/{realm}/mcp-picker-callback} here. The
     * {@code picker_result} query param carries the signed JWT from YourApp web.
     */
    @GET
    @Path("/")
    public Response handleCallback(@QueryParam("picker_result") String pickerResult)
    {
        RealmModel realm = session.getContext().getRealm();
        String realmName = realm.getName();

        if (pickerResult == null || pickerResult.isBlank())
        {
            log.warnf("Picker callback realm=%s missing picker_result query param",
                    realmName);
            return badRequest("missing_token", null);
        }

        PickerResultToken token;
        try
        {
            token = validator.validatePickerResult(pickerResult, realmName);
        }
        catch (HandoffValidationException ex)
        {
            log.warnf("Picker-result validation failed realm=%s code=%s",
                    realmName, ex.getCode());
            return badRequest("invalid_handoff", ex.getCode().name());
        }
        catch (McpSpiConfigException ex)
        {
            log.errorf("Realm %s HMAC key not configured: code=%s envVar=%s",
                    realmName, ex.getCode(), ex.getParameterName());
            return badRequest("realm_misconfigured", ex.getCode().name());
        }

        // The suspended-session correlation claims (kc_client_id, kc_tab_id,
        // auth_session_id) are echoed by the app from the picker-request. If they
        // are absent, the app is not honouring the picker-result contract (web
        // spec §3.3 / ERRATA-003) — fail with a precise, actionable code rather
        // than a misleading client_not_found (which reads as "the client id you
        // sent doesn't exist" when the real problem is "you sent no client id").
        if (isBlank(token.getKcClientId()) || isBlank(token.getKcTabId())
                || isBlank(token.getAuthSessionId()))
        {
            log.warnf("Picker callback realm=%s missing correlation claims "
                    + "(kc_client_id present=%s, kc_tab_id present=%s, "
                    + "auth_session_id present=%s) — the app must echo these from "
                    + "the picker-request into the picker-result; see web spec "
                    + "§3.3 / ERRATA-003",
                    realmName, !isBlank(token.getKcClientId()),
                    !isBlank(token.getKcTabId()), !isBlank(token.getAuthSessionId()));
            return badRequest("missing_correlation", null);
        }

        ClientModel client = realm.getClientByClientId(token.getKcClientId());
        if (client == null)
        {
            log.warnf("Picker callback realm=%s client=%s not found",
                    realmName, token.getKcClientId());
            return badRequest("client_not_found", null);
        }

        AuthenticationSessionModel authSession = findAuthSession(realm, client, token);
        if (authSession == null)
        {
            log.warnf("Picker callback realm=%s client=%s tab=%s auth session not found",
                    realmName, token.getKcClientId(), token.getKcTabId());
            return badRequest("session_not_found", null);
        }

        UserModel currentUser = authSession.getAuthenticatedUser();
        if (currentUser == null || !currentUser.getId().equals(token.getUserSubEcho()))
        {
            log.warnf("Picker callback realm=%s user mismatch session=%s echo=%s",
                    realmName,
                    currentUser == null ? "null" : currentUser.getId(),
                    token.getUserSubEcho());
            return badRequest("user_mismatch", null);
        }

        writeSessionNotes(authSession, token);

        log.infof("Picker-result accepted user=%s realm=%s tenant=%s scopes=%s",
                currentUser.getId(), realmName,
                token.getChosenTenantId(), token.getGrantedScopes());

        URI resumeUrl = resumeUrlBuilder.build(session, realm, authSession);
        return Response.seeOther(resumeUrl).build();
    }

    // ----------------------------------------------------------------- helpers

    private AuthenticationSessionModel findAuthSession(
            RealmModel realm, ClientModel client, PickerResultToken token)
    {
        AuthenticationSessionManager manager = managerFactory.apply(session);
        AuthenticationSessionModel authSession =
                manager.getCurrentAuthenticationSession(realm, client, token.getKcTabId());
        if (authSession != null)
        {
            return authSession;
        }
        // Fallback when the AUTH_SESSION_ID cookie was dropped on the round-trip
        // (e.g., third-party cookie blockers). The auth_session_id claim is
        // HMAC-protected inside the JWT, so this fallback is safe.
        return manager.getAuthenticationSessionByIdAndClient(realm,
                token.getAuthSessionId(), client, token.getKcTabId());
    }

    private static void writeSessionNotes(
            AuthenticationSessionModel authSession, PickerResultToken token)
    {
        authSession.setUserSessionNote(SESSION_NOTE_TENANT_ID,
                token.getChosenTenantId());
        List<String> scopes = token.getGrantedScopes();
        authSession.setUserSessionNote(SESSION_NOTE_SCOPES,
                (scopes == null || scopes.isEmpty())
                        ? ""
                        : String.join(" ", scopes));
    }

    private static URI defaultResumeUrl(KeycloakSession session, RealmModel realm,
            AuthenticationSessionModel authSession)
    {
        return new AuthenticationFlowURLHelper(session, realm,
                session.getContext().getUri())
                .getLastExecutionUrl(authSession);
    }

    private static boolean isBlank(String value)
    {
        return value == null || value.isBlank();
    }

    private static Response badRequest(String error, String description)
    {
        Map<String, String> body = (description == null)
                ? Map.of("error", error)
                : Map.of("error", error, "error_description", description);
        return Response.status(Response.Status.BAD_REQUEST)
                .entity(body)
                .type(MediaType.APPLICATION_JSON)
                .build();
    }
}
