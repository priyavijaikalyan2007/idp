/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: f7bef3c1-b8e9-46ba-bc70-074ef6c9dea0
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpTenantPickerAuthenticator
 * 📜 PURPOSE: Final step of the browser-mcp-tenant-pick flow. Builds a signed
 *             picker-request JWT carrying the user / client / scope / OAuth
 *             state and the Keycloak auth-session correlation fields, then
 *             302-redirects the browser to Knobby web's /mcp/consent endpoint.
 *             Suspends the authentication flow via context.challenge.
 * 🔗 RELATES: [[McpTenantPickerAuthenticatorFactory]], [[HandoffTokenSigner]],
 *             [[PickerRequestToken]], [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [Keycloak auth flow] -> [this.authenticate]
 *         -> [HandoffTokenSigner.sign] -> [302 to https://{host}/mcp/consent]
 * 🛡️ SECURITY: Per-realm HMAC key (via signer). knobby.web.host read from
 *              per-realm Authenticator config (admin-controlled). Failures
 *              never leak key material or PII into logs (id-only).
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.authenticator;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import jakarta.ws.rs.core.Response;

import org.jboss.logging.Logger;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.AuthenticationFlowError;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.AuthenticatorConfigModel;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.sessions.AuthenticationSessionModel;

import io.knobby.keycloak.mcp.config.McpSpiConfigException;
import io.knobby.keycloak.mcp.jwt.HandoffTokenSigner;
import io.knobby.keycloak.mcp.jwt.PickerRequestToken;

/**
 * Stateless per-request handler. The factory owns the cached
 * {@link HandoffTokenSigner}; instances of this class are created per flow
 * step and discarded.
 *
 * <p>See {@code keycloak.spi.mcp.md} §5.1 and the suspend / resume design in
 * {@code keycloak.spi.mcp.status.md} §3.5.
 */
public final class McpTenantPickerAuthenticator implements Authenticator
{
    private static final Logger log = Logger.getLogger(McpTenantPickerAuthenticator.class);

    /** Per-realm Authenticator config key for the Knobby web hostname. */
    static final String CONFIG_KEY_WEB_HOST = "knobby.web.host";

    /**
     * Intrinsic MCP marker attribute, set atomically at registration by
     * {@code McpClientRegistrationPolicy} (§5.8). This is the PREFERRED MCP
     * signal: unlike a client scope, it cannot be accidentally acquired by a
     * non-MCP client via a realm-default scope assignment.
     */
    static final String MCP_CLIENT_ATTRIBUTE = "knobby.mcp";
    static final String MCP_CLIENT_ATTRIBUTE_VALUE = "true";

    /**
     * Client scope whose presence also marks a client as MCP-enabled. Retained
     * as a fallback detection signal behind {@link #MCP_CLIENT_ATTRIBUTE} (see
     * the short-circuit guard in {@link #authenticate}).
     */
    static final String MCP_CLIENT_SCOPE = "mcp-default";

    /** Constants required by Knobby web's picker-request validator. */
    static final String ISSUER = "keycloak-mcp-spi";
    static final String AUDIENCE = "knobby-web-mcp-consent";

    /** Picker-request TTL in seconds (5 min, per spec §6.1). */
    static final long TTL_SECONDS = 300L;

    /** Nonce size in bytes; hex-encoded into a 32-char string. */
    static final int NONCE_BYTES = 16;

    private final HandoffTokenSigner signer;
    private final Clock clock;
    private final Supplier<String> nonceSupplier;
    private final Supplier<String> jtiSupplier;

    /** Production constructor: SecureRandom nonces, UUID jtis, system UTC clock. */
    public McpTenantPickerAuthenticator(HandoffTokenSigner signer)
    {
        this(signer, Clock.systemUTC(), defaultNonceSupplier(), defaultJtiSupplier());
    }

    /** Test seam: deterministic nonces / jtis / clock for assertion stability. */
    McpTenantPickerAuthenticator(
            HandoffTokenSigner signer,
            Clock clock,
            Supplier<String> nonceSupplier,
            Supplier<String> jtiSupplier)
    {
        this.signer = signer;
        this.clock = clock;
        this.nonceSupplier = nonceSupplier;
        this.jtiSupplier = jtiSupplier;
    }

    @Override
    public void authenticate(AuthenticationFlowContext context)
    {
        AuthenticationSessionModel authSession = context.getAuthenticationSession();

        // Short-circuit guard (spec §5.1) — SAFETY NET ONLY, not load-bearing.
        // Under the settled design, McpClientRegistrationPolicy (§5.8) binds this
        // flow to MCP clients atomically at registration, and the realm default
        // stays browser-federated-only, so this step only ever runs for real MCP
        // clients. This guard exists solely to fail safe if someone misconfigures
        // the realm (makes this the default flow, or binds a non-MCP client by
        // mistake): a non-MCP client passes through untouched. Correctness comes
        // from the atomic binding at registration, NOT from this check.
        ClientModel client = authSession.getClient();
        if (!isMcpClient(client))
        {
            if (log.isDebugEnabled())
            {
                log.debugf("Skipping MCP picker for non-MCP client=%s realm=%s",
                        client.getClientId(), context.getRealm().getName());
            }
            context.success();
            return;
        }

        UserModel user = context.getUser();
        if (user == null)
        {
            log.error("MCP picker step reached without an authenticated user "
                    + "— flow misconfigured (must run after federated auth).");
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
            return;
        }

        RealmModel realm = context.getRealm();
        String realmName = realm.getName();

        String knobbyWebHost = resolveWebHost(context, realmName);
        if (knobbyWebHost == null)
        {
            return;
        }

        PickerRequestToken request = buildRequest(user, authSession);
        String signed;
        try
        {
            signed = signer.sign(request, realmName);
        }
        catch (McpSpiConfigException ex)
        {
            log.errorf("MCP HMAC key not configured realm=%s code=%s envVar=%s",
                    realmName, ex.getCode(), ex.getParameterName());
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
            return;
        }

        URI redirect = buildRedirectUri(knobbyWebHost, signed);
        log.infof("Emitting MCP picker request user=%s client=%s realm=%s jti=%s",
                user.getId(), authSession.getClient().getClientId(),
                realmName, request.getJti());

        context.challenge(Response.seeOther(redirect).build());
    }

    @Override
    public void action(AuthenticationFlowContext context)
    {
        // The user returns via the McpPickerCallbackResourceProvider endpoint,
        // NOT via this authenticator's action endpoint. Hitting action() means
        // either a bug or an attempted bypass; fail the flow.
        log.warn("Unexpected action() call on McpTenantPickerAuthenticator; "
                + "the flow resumes via the mcp-picker-callback resource provider, "
                + "not via direct form POSTs.");
        context.failure(AuthenticationFlowError.INTERNAL_ERROR);
    }

    @Override
    public boolean requiresUser()
    {
        return true;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user)
    {
        return true;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user)
    {
        // No required actions to set.
    }

    @Override
    public void close()
    {
        // No resources to close.
    }

    // ---------------------------------------------------------------- helpers

    /**
     * An MCP client is identified, in preference order, by the intrinsic
     * {@code knobby.mcp="true"} attribute the registration policy sets (§5.8),
     * falling back to presence of the {@code mcp-default} client scope (default
     * or optional). Regular web logins and service clients have neither, so the
     * picker redirect is skipped for them.
     */
    private static boolean isMcpClient(ClientModel client)
    {
        if (MCP_CLIENT_ATTRIBUTE_VALUE.equals(client.getAttribute(MCP_CLIENT_ATTRIBUTE)))
        {
            return true;
        }
        return client.getClientScopes(true).containsKey(MCP_CLIENT_SCOPE)
                || client.getClientScopes(false).containsKey(MCP_CLIENT_SCOPE);
    }

    private String resolveWebHost(AuthenticationFlowContext context, String realmName)
    {
        AuthenticatorConfigModel authConfig = context.getAuthenticatorConfig();
        String host = (authConfig == null)
                ? null
                : authConfig.getConfig().get(CONFIG_KEY_WEB_HOST);
        if (host == null || host.isBlank())
        {
            log.errorf("Authenticator config missing %s realm=%s — "
                    + "set the property on the browser-mcp-tenant-pick flow's "
                    + "Knobby MCP Tenant Picker step in the admin console.",
                    CONFIG_KEY_WEB_HOST, realmName);
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
            return null;
        }
        return host;
    }

    private PickerRequestToken buildRequest(UserModel user, AuthenticationSessionModel authSession)
    {
        long now = Instant.now(clock).getEpochSecond();
        return PickerRequestToken.builder()
                .iss(ISSUER)
                .aud(AUDIENCE)
                .sub(user.getId())
                .knobbySub(user.getId())
                .mcpClientId(authSession.getClient().getClientId())
                .mcpRequestedScopes(orderedScopeNames(authSession.getClientScopes()))
                .oauthState(authSession.getClientNote(OIDCLoginProtocol.STATE_PARAM))
                .authSessionId(authSession.getParentSession().getId())
                .kcClientId(authSession.getClient().getClientId())
                .kcTabId(authSession.getTabId())
                .nonce(nonceSupplier.get())
                .jti(jtiSupplier.get())
                .iat(now)
                .exp(now + TTL_SECONDS)
                .build();
    }

    private static URI buildRedirectUri(String knobbyWebHost, String signedToken)
    {
        String encoded = URLEncoder.encode(signedToken, StandardCharsets.UTF_8);
        return URI.create("https://" + knobbyWebHost + "/mcp/consent?token=" + encoded);
    }

    private static List<String> orderedScopeNames(Set<String> scopes)
    {
        if (scopes == null || scopes.isEmpty())
        {
            return List.of();
        }
        List<String> sorted = new ArrayList<>(scopes);
        Collections.sort(sorted);
        return List.copyOf(sorted);
    }

    private static Supplier<String> defaultNonceSupplier()
    {
        SecureRandom rng = new SecureRandom();
        HexFormat hex = HexFormat.of();
        return () ->
        {
            byte[] bytes = new byte[NONCE_BYTES];
            rng.nextBytes(bytes);
            return hex.formatHex(bytes);
        };
    }

    private static Supplier<String> defaultJtiSupplier()
    {
        return () -> UUID.randomUUID().toString();
    }
}
