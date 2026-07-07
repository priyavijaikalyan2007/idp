/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: f58d1c98-4c61-431e-bf2b-b35e32e8b194
 * Repository: knobby/idp
 * Created: 2026-07-06
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpClientRegistrationPolicy
 * 📜 PURPOSE: Client Registration Policy that marks every anonymously-DCR'd MCP
 *             client ATOMICALLY at registration (spec §5.8). In afterRegister,
 *             on the live ClientModel and inside the registration transaction,
 *             it: (1) sets the knobby.mcp="true" attribute, (2) assigns the
 *             configured default + optional MCP client scopes (removing any
 *             DCR-prebound binding first so default/optional placement is
 *             authoritative — ERRATA-005), (3) binds the browser flow override to
 *             browser-mcp-tenant-pick, and (4) sets consentRequired=false so the
 *             knobby /mcp/consent wizard is the sole consent surface. Because the
 *             mutations share the registration transaction, the client either
 *             registers fully-marked or the registration rolls back — no partial
 *             states, so no reconciliation logic is needed.
 * 🔗 RELATES: [[McpClientRegistrationPolicyFactory]], [[McpTenantPickerAuthenticator]]
 * ⚡ FLOW: [anonymous DCR] -> [Keycloak registration tx]
 *         -> [this.afterRegister mutates ClientModel] -> [commit | rollback]
 * 🛡️ SECURITY: Bound as an ANONYMOUS CRP, so it governs only self-registered DCR
 *              clients, never admin-created first-party clients. A missing scope
 *              or flow throws (rolls back) rather than registering a half-marked
 *              client. No secrets touched; no PII logged (client id only).
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.clientreg;

import java.util.List;

import org.jboss.logging.Logger;
import org.keycloak.models.AuthenticationFlowBindings;
import org.keycloak.models.AuthenticationFlowModel;
import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientScopeModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.component.ComponentModel;
import org.keycloak.services.clientregistration.ClientRegistrationContext;
import org.keycloak.services.clientregistration.ClientRegistrationProvider;
import org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy;
import org.keycloak.services.clientregistration.policy.ClientRegistrationPolicyException;

/**
 * Stateless per-registration handler. Keycloak's {@code ComponentFactory}
 * machinery constructs one per registration via the factory's
 * {@code create(session, model)}; the only state is the session and the
 * component's configuration.
 *
 * <p>See {@code keycloak.spi.mcp.md} §5.8. The paired short-circuit safety net
 * lives in {@link io.knobby.keycloak.mcp.authenticator.McpTenantPickerAuthenticator}
 * (§5.1) — correctness comes from the atomic binding here, not from that guard.
 */
public final class McpClientRegistrationPolicy implements ClientRegistrationPolicy
{
    private static final Logger log = Logger.getLogger(McpClientRegistrationPolicy.class);

    /**
     * Intrinsic MCP marker attribute. Set here at registration and read (in
     * preference to scope presence) by the tenant-picker authenticator's
     * short-circuit guard. Kept as a constant — not admin-tunable — because both
     * the writer (this policy) and the reader (the authenticator) must agree on
     * it exactly.
     */
    public static final String MCP_ATTRIBUTE = "knobby.mcp";
    public static final String MCP_ATTRIBUTE_VALUE = "true";

    private final KeycloakSession session;
    private final ComponentModel componentModel;

    McpClientRegistrationPolicy(KeycloakSession session, ComponentModel componentModel)
    {
        this.session = session;
        this.componentModel = componentModel;
    }

    @Override
    public void afterRegister(ClientRegistrationContext context, ClientModel client)
    {
        RealmModel realm = session.getContext().getRealm();

        // 1. Mark as MCP — an intrinsic signal, independent of what scopes the
        //    client happened to request during DCR.
        client.setAttribute(MCP_ATTRIBUTE, MCP_ATTRIBUTE_VALUE);

        // 2. Assign the author-bundle default scopes and the optional scope(s).
        //    Default scopes are granted whether or not the client asks for them.
        assignScopes(realm, client, defaultScopes(), true);
        assignScopes(realm, client, optionalScopes(), false);

        // 3. Bind the MCP browser flow as a per-client override. This is what
        //    routes the client's FIRST authorization through the tenant picker.
        bindBrowserFlow(realm, client);

        // 4. Suppress Keycloak's built-in OAuth consent screen. The knobby web
        //    /mcp/consent wizard is the authoritative consent surface (it collects
        //    the tenant + scope grants); Keycloak's own OAUTH_GRANT screen after it
        //    is redundant double-consent (ERRATA-005). The mcp-hardening
        //    consent-required client-policy executor sets consentRequired=true, but
        //    it runs on the DynamicClientRegistered event (triggerOnEvent) BEFORE
        //    this policy's afterRegister (triggerAfterRegister) — verified against
        //    the 26.6.0 AbstractClientRegistrationProvider bytecode — so this
        //    setter is the last word and wins.
        client.setConsentRequired(false);

        log.infof("Marked MCP client at registration client=%s realm=%s "
                + "(attribute + %d default / %d optional scopes + browser flow "
                + "+ consent suppressed)",
                client.getClientId(), realm.getName(),
                defaultScopes().size(), optionalScopes().size());

        // Any throw above rolls back the ENTIRE registration transaction, so a
        // client is never persisted half-marked.
    }

    // ---------------------------------------------------------------- helpers

    private void assignScopes(RealmModel realm, ClientModel client,
            List<String> scopeNames, boolean asDefault)
    {
        for (String name : scopeNames)
        {
            ClientScopeModel scope = KeycloakModelUtils.getClientScopeByName(realm, name);
            if (scope == null)
            {
                throw new ClientRegistrationPolicyException(
                        "Required MCP client scope missing: " + name
                        + " — create it per setup guide D.3/D.4 before enabling "
                        + "the MCP registration policy.");
            }
            // The OIDC DCR request's `scope` field may have ALREADY bound this
            // scope as OPTIONAL before this policy's afterRegister runs.
            // ClientModel.addClientScope is a no-op when a binding already exists,
            // so it will NOT promote an existing optional binding to default —
            // leaving mcp-default + the author bundle as optional and off the
            // client's default-client-scopes (ERRATA-005). Remove any existing
            // binding first so THIS policy's default/optional placement is
            // authoritative, regardless of what the DCR request requested.
            client.removeClientScope(scope);
            client.addClientScope(scope, asDefault);
        }
    }

    private void bindBrowserFlow(RealmModel realm, ClientModel client)
    {
        String alias = flowAlias();
        AuthenticationFlowModel flow = realm.getFlowByAlias(alias);
        if (flow == null)
        {
            throw new ClientRegistrationPolicyException(
                    "MCP browser flow not found: " + alias
                    + " — create it per setup guide D.2 before enabling the MCP "
                    + "registration policy.");
        }
        client.setAuthenticationFlowBindingOverride(
                AuthenticationFlowBindings.BROWSER_BINDING, flow.getId());
    }

    private List<String> defaultScopes()
    {
        return configuredList(McpClientRegistrationPolicyFactory.CFG_DEFAULT_SCOPES,
                McpClientRegistrationPolicyFactory.DEFAULT_SCOPES_FALLBACK);
    }

    private List<String> optionalScopes()
    {
        return configuredList(McpClientRegistrationPolicyFactory.CFG_OPTIONAL_SCOPES,
                McpClientRegistrationPolicyFactory.OPTIONAL_SCOPES_FALLBACK);
    }

    private String flowAlias()
    {
        return componentModel.get(McpClientRegistrationPolicyFactory.CFG_FLOW_ALIAS,
                McpClientRegistrationPolicyFactory.FLOW_ALIAS_FALLBACK);
    }

    /**
     * Reads a multi-valued config entry, falling back to the policy default when
     * an admin has not overridden it. An empty override is treated as "unset".
     */
    private List<String> configuredList(String key, List<String> fallback)
    {
        List<String> configured = componentModel.getConfig().get(key);
        if (configured == null || configured.isEmpty())
        {
            return fallback;
        }
        return configured;
    }

    // -------------------------------------------------------- no-op lifecycle

    @Override
    public void beforeRegister(ClientRegistrationContext context)
    {
        // Intentional no-op. The deferred grant-type rejection (register B1,
        // spec §5.8) will live here when the DCR-hardening pass folds it in.
    }

    @Override
    public void afterUpdate(ClientRegistrationContext context, ClientModel client)
    {
        // No-op: marking happens once, at registration.
    }

    @Override
    public void beforeUpdate(ClientRegistrationContext context, ClientModel client)
    {
        // No-op.
    }

    @Override
    public void beforeView(ClientRegistrationProvider provider, ClientModel client)
    {
        // No-op.
    }

    @Override
    public void beforeDelete(ClientRegistrationProvider provider, ClientModel client)
    {
        // No-op.
    }

    @Override
    public void close()
    {
        // No resources to close.
    }
}
