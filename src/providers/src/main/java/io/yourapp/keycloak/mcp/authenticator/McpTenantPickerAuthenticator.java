/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: f7bef3c1-b8e9-46ba-bc70-074ef6c9dea0
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpTenantPickerAuthenticator
 * 📜 PURPOSE: The MCP tenant-picker step. Hosted in TWO flows (ERRATA-005): the
 *             browser-mcp-tenant-pick flow (Cookie / already-logged-in path) and
 *             the Post Broker Login Flow (fresh / IdP-redirect path) — because
 *             browser-flow executions after an IdP redirect don't run for brokered
 *             logins. Both converge on identical behavior. A RE-ENTRANT
 *             suspend/resume step (ERRATA-004): authenticate() first checks the
 *             resume note (yourapp.mcp.picker.completed) the callback writes — if
 *             set, it finishes the step; otherwise it builds a signed
 *             picker-request JWT carrying the user / client / scope / OAuth state
 *             and the Keycloak auth-session correlation fields, then 302-redirects
 *             the browser to YourApp web's /mcp/consent endpoint, suspending the
 *             flow via context.challenge.
 * 🔗 RELATES: [[McpTenantPickerAuthenticatorFactory]], [[HandoffTokenSigner]],
 *             [[PickerRequestToken]], [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [Keycloak auth flow] -> [this.authenticate]
 *         -> resume note set ? [context.success] (finish)
 *         : [HandoffTokenSigner.sign] -> [302 to https://{host}/mcp/consent]
 *         -> [/mcp-picker-callback sets note] -> [resume re-enters authenticate]
 * 🛡️ SECURITY: Per-realm HMAC key (via signer). yourapp.web.host read from
 *              per-realm Authenticator config (admin-controlled). Failures
 *              never leak key material or PII into logs (id-only).
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.authenticator;

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
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import java.util.regex.Pattern;

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

import io.yourapp.keycloak.mcp.config.McpSpiConfigException;
import io.yourapp.keycloak.mcp.jwt.HandoffTokenSigner;
import io.yourapp.keycloak.mcp.jwt.PickerRequestToken;

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

    /** Per-realm Authenticator config key for the YourApp web hostname. */
    static final String CONFIG_KEY_WEB_HOST = "yourapp.web.host";

    /**
     * Intrinsic MCP marker attribute, set atomically at registration by
     * {@code McpClientRegistrationPolicy} (§5.8). This is the PREFERRED MCP
     * signal: unlike a client scope, it cannot be accidentally acquired by a
     * non-MCP client via a realm-default scope assignment.
     */
    static final String MCP_CLIENT_ATTRIBUTE = "yourapp.mcp";
    static final String MCP_CLIENT_ATTRIBUTE_VALUE = "true";

    /**
     * Client scope whose presence also marks a client as MCP-enabled. Retained
     * as a fallback detection signal behind {@link #MCP_CLIENT_ATTRIBUTE} (see
     * the short-circuit guard in {@link #authenticate}).
     */
    static final String MCP_CLIENT_SCOPE = "mcp-default";

    /**
     * Auth-session note set by the {@code McpPickerCallbackResourceProvider}
     * once it has validated a picker-result and recorded the consent (tenant +
     * scopes) on this auth session. It is the RESUME signal: the callback
     * re-enters the suspended flow via {@code getLastExecutionUrl}, which
     * re-invokes {@link #authenticate} (NOT {@code action}). Without checking
     * this note, {@code authenticate} would build a fresh picker-request and
     * redirect to {@code /mcp/consent} again — an infinite loop (ERRATA-004).
     * Public because the callback writes this exact key; the two MUST agree.
     */
    public static final String AUTH_NOTE_PICKER_COMPLETED =
            "yourapp.mcp.picker.completed";

    /**
     * Auth-session note holding the picker-request's {@code jti}, written just
     * before the redirect. The callback requires the picker-result to echo THIS
     * value (RT-008) so a signed result for a different request cannot be accepted
     * for this session — HMAC validity alone is not sufficient binding.
     */
    public static final String AUTH_NOTE_PICKER_REQUEST_JTI =
            "yourapp.mcp.picker.request.jti";

    /** Constants required by YourApp web's picker-request validator. */
    static final String ISSUER = "keycloak-mcp-spi";
    static final String AUDIENCE = "yourapp-web-mcp-consent";

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

        // Resume guard (spec §5.3, ERRATA-004) — MUST be first. When the app
        // posts a valid picker-result, McpPickerCallbackResourceProvider records
        // the consent on this auth session and re-enters the flow via
        // getLastExecutionUrl, which re-invokes authenticate() (Keycloak resumes
        // a CHALLENGED execution through authenticate(), not action()). This
        // authenticator is therefore a suspend/resume step and must be
        // re-entrant: if the callback already completed the out-of-band consent,
        // finish the step instead of issuing a fresh picker-request — otherwise
        // it redirects to /mcp/consent forever.
        if (Boolean.parseBoolean(authSession.getAuthNote(AUTH_NOTE_PICKER_COMPLETED)))
        {
            log.infof("MCP picker resume: consent already recorded, completing "
                    + "step client=%s realm=%s",
                    authSession.getClient().getClientId(),
                    context.getRealm().getName());
            context.success();
            return;
        }

        // MCP-client detection guard (spec §5.1). Its role depends on WHICH flow
        // hosts this step:
        //   - In browser-mcp-tenant-pick (per-client bound by the CRP, §5.8): a
        //     SAFETY NET — only MCP clients are ever routed here, so this is
        //     belt-and-suspenders.
        //   - In the Post Broker Login Flow (ERRATA-005): LOAD-BEARING. That flow
        //     is per-IdP and shared with regular web-app logins (they use the same
        //     Google/Microsoft IdPs), so this guard is the ONLY thing that keeps
        //     the tenant picker from firing on non-MCP web logins. Do NOT remove it.
        // Either way a non-MCP client passes through untouched via context.success().
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

        String yourappWebHost = resolveWebHost(context, realmName);
        if (yourappWebHost == null)
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

        // RT-008: remember this request's jti so the callback can require the
        // picker-result to echo it (request↔result binding).
        authSession.setAuthNote(AUTH_NOTE_PICKER_REQUEST_JTI, request.getJti());

        URI redirect = buildRedirectUri(yourappWebHost, signed);
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
     * {@code yourapp.mcp="true"} attribute the registration policy sets (§5.8),
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

    /**
     * Per-realm allowlist of the ONLY host a signed picker-request may be sent to
     * (RT-011), pinned in code for internet-facing realms so a misconfigured or
     * compromised admin cannot redirect handoff tokens (which carry user / client /
     * auth-session metadata + OAuth state) to an attacker-controlled host. Realms
     * not listed here (test / local) fall back to strict syntax validation only.
     * Adding a new production-facing realm means adding it here.
     */
    static final Map<String, String> ALLOWED_HOSTS_BY_REALM = Map.of(
            "yourapp-prod", "prod.yourapp.com",
            "yourapp-dev", "dev.yourapp.com");

    /** A single LDH hostname label (letters/digits/hyphen, no leading/trailing hyphen). */
    private static final Pattern HOSTNAME_LABEL =
            Pattern.compile("[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?");

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
                    + "YourApp MCP Tenant Picker step in the admin console.",
                    CONFIG_KEY_WEB_HOST, realmName);
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
            return null;
        }
        host = host.trim();

        // RT-011: fail closed on anything that isn't a bare hostname. The redirect
        // URI is built by string concatenation (https://<host>/mcp/consent), so a
        // value carrying a scheme, port, path, userinfo, or whitespace is a
        // redirect-forgery vector.
        if (!isValidHostname(host))
        {
            log.errorf("Authenticator config %s=%s realm=%s is not a bare hostname "
                    + "(no scheme/port/path/userinfo/whitespace) — refusing (RT-011).",
                    CONFIG_KEY_WEB_HOST, host, realmName);
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
            return null;
        }

        // RT-011: for internet-facing realms the host is pinned in code; reject any
        // other value even if it is a syntactically valid hostname.
        String pinned = ALLOWED_HOSTS_BY_REALM.get(realmName);
        if (pinned != null && !pinned.equals(host))
        {
            log.errorf("Authenticator config %s=%s realm=%s is not the allowlisted "
                    + "host %s — refusing (RT-011).",
                    CONFIG_KEY_WEB_HOST, host, realmName, pinned);
            context.failure(AuthenticationFlowError.INTERNAL_ERROR);
            return null;
        }
        return host;
    }

    /** True iff {@code host} is a dot-separated series of LDH labels, total ≤253. */
    private static boolean isValidHostname(String host)
    {
        if (host.length() > 253)
        {
            return false;
        }
        for (String label : host.split("\\.", -1))
        {
            if (!HOSTNAME_LABEL.matcher(label).matches())
            {
                return false;
            }
        }
        return true;
    }

    private PickerRequestToken buildRequest(UserModel user, AuthenticationSessionModel authSession)
    {
        long now = Instant.now(clock).getEpochSecond();
        return PickerRequestToken.builder()
                .iss(ISSUER)
                .aud(AUDIENCE)
                .sub(user.getId())
                .yourappSub(user.getId())
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

    private static URI buildRedirectUri(String yourappWebHost, String signedToken)
    {
        String encoded = URLEncoder.encode(signedToken, StandardCharsets.UTF_8);
        return URI.create("https://" + yourappWebHost + "/mcp/consent?token=" + encoded);
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
