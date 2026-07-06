/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 9587cb78-ec48-4d1f-bedf-09644cc7d4ee
 * Repository: yourapp/idp
 * Created: 2026-07-06
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpClientRegistrationPolicyFactory
 * 📜 PURPOSE: Keycloak SPI factory for McpClientRegistrationPolicy (spec §5.8).
 *             Extends AbstractClientRegistrationPolicyFactory so the policy
 *             appears in the admin console under Clients → Client registration →
 *             Anonymous Access Policies, where an operator registers it as an
 *             anonymous-subtype policy. Exposes the tunable scope lists + flow
 *             alias as ComponentModel config properties (config-driven per the
 *             2026-07-06 decision), each pre-filled with the settled defaults.
 * 🔗 RELATES: [[McpClientRegistrationPolicy]]
 * ⚡ FLOW: [Keycloak SPI loader] -> [this.create(session, model)]
 *         -> [McpClientRegistrationPolicy per registration]
 * 🛡️ SECURITY: Config is non-sensitive routing (scope names, flow alias); no
 *              secrets pass through the admin console.
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.clientreg;

import java.util.List;

import org.keycloak.component.ComponentModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.provider.ProviderConfigurationBuilder;
import org.keycloak.services.clientregistration.policy.AbstractClientRegistrationPolicyFactory;
import org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy;

/**
 * Single instance per Keycloak JVM. See {@code keycloak.spi.mcp.md} §5.8 and
 * setup guide D.7/D.8 for the deployment (register as an <em>anonymous</em>
 * Client Registration Policy).
 */
public final class McpClientRegistrationPolicyFactory
        extends AbstractClientRegistrationPolicyFactory
{
    /** Provider id surfaced to admins and referenced from realm config. */
    public static final String PROVIDER_ID = "yourapp-mcp-registration";

    /** Config keys (ComponentModel). */
    public static final String CFG_DEFAULT_SCOPES = "default-scopes";
    public static final String CFG_OPTIONAL_SCOPES = "optional-scopes";
    public static final String CFG_FLOW_ALIAS = "flow-alias";

    /**
     * Settled defaults (spec §5.8, setup guide D.7). Used both as the admin-console
     * pre-fill and as the policy's runtime fallback when config is left unset.
     */
    static final List<String> DEFAULT_SCOPES_FALLBACK = List.of(
            "mcp-default",
            "yourapp:read", "yourapp:comment", "yourapp:curate",
            "yourapp:write", "yourapp:share");
    static final List<String> OPTIONAL_SCOPES_FALLBACK = List.of("yourapp:admin");
    static final String FLOW_ALIAS_FALLBACK = "browser-mcp-tenant-pick";

    private static final String HELP_TEXT =
            "Marks every anonymously-registered (DCR) MCP client atomically at "
                    + "registration: assigns the MCP default + optional client "
                    + "scopes, sets the yourapp.mcp attribute, and binds the "
                    + "browser flow so the client's first authorization routes "
                    + "through the tenant picker. Register as an Anonymous "
                    + "Access Policy. See SPI design §5.8.";

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES =
            ProviderConfigurationBuilder.create()
                    .property()
                        .name(CFG_DEFAULT_SCOPES)
                        .label("Default MCP scopes")
                        .helpText("Client scopes assigned as DEFAULT (granted "
                                + "whether or not the client requests them) to "
                                + "each DCR'd MCP client. Must already exist in "
                                + "the realm (setup guide D.3/D.4).")
                        .type(ProviderConfigProperty.MULTIVALUED_STRING_TYPE)
                        .defaultValue(DEFAULT_SCOPES_FALLBACK)
                        .add()
                    .property()
                        .name(CFG_OPTIONAL_SCOPES)
                        .label("Optional MCP scopes")
                        .helpText("Client scopes assigned as OPTIONAL (granted "
                                + "only when the client requests them) to each "
                                + "DCR'd MCP client.")
                        .type(ProviderConfigProperty.MULTIVALUED_STRING_TYPE)
                        .defaultValue(OPTIONAL_SCOPES_FALLBACK)
                        .add()
                    .property()
                        .name(CFG_FLOW_ALIAS)
                        .label("Browser flow alias")
                        .helpText("Alias of the authentication flow to bind as "
                                + "the client's browser flow override. Must "
                                + "already exist in the realm (setup guide D.2).")
                        .type(ProviderConfigProperty.STRING_TYPE)
                        .defaultValue(FLOW_ALIAS_FALLBACK)
                        .add()
                    .build();

    @Override
    public String getId()
    {
        return PROVIDER_ID;
    }

    @Override
    public ClientRegistrationPolicy create(KeycloakSession session, ComponentModel model)
    {
        return new McpClientRegistrationPolicy(session, model);
    }

    @Override
    public String getHelpText()
    {
        return HELP_TEXT;
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties()
    {
        return CONFIG_PROPERTIES;
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties(KeycloakSession session)
    {
        return CONFIG_PROPERTIES;
    }
}
