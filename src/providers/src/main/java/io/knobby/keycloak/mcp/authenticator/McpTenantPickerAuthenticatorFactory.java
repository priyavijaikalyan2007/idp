/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 30a4676d-51a5-428d-8167-1d037023be84
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpTenantPickerAuthenticatorFactory
 * 📜 PURPOSE: Keycloak SPI factory for McpTenantPickerAuthenticator. Owns the
 *             singleton McpSpiConfig + HandoffTokenSigner (per-realm key cache
 *             survives across requests). Exposes the per-realm knobby.web.host
 *             property to the admin console. Logs the loaded-realms set at
 *             startup.
 * 🔗 RELATES: [[McpTenantPickerAuthenticator]], [[McpSpiConfig]],
 *             [[HandoffTokenSigner]]
 * ⚡ FLOW: [Keycloak SPI loader] -> [this.init / create]
 *         -> [Authenticator instances]
 * 🛡️ SECURITY: knobby.web.host is non-sensitive routing config; HMAC keys
 *              remain in env vars (never in the admin console).
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.authenticator;

import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import org.jboss.logging.Logger;
import org.keycloak.Config;
import org.keycloak.authentication.Authenticator;
import org.keycloak.authentication.AuthenticatorFactory;
import org.keycloak.models.AuthenticationExecutionModel.Requirement;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;

import io.knobby.keycloak.mcp.config.McpSpiConfig;
import io.knobby.keycloak.mcp.jwt.HandoffTokenSigner;

/**
 * Single instance per Keycloak JVM. Methods are called by Keycloak's SPI
 * machinery; the only state held is the lazily-built signer reference, which
 * Keycloak guarantees is initialised via {@link #init} before any
 * {@link #create} call.
 *
 * <p>See {@code keycloak.spi.mcp.md} §5.2.
 */
public final class McpTenantPickerAuthenticatorFactory implements AuthenticatorFactory
{
    private static final Logger log =
            Logger.getLogger(McpTenantPickerAuthenticatorFactory.class);

    /** Provider id surfaced to admins and referenced from realm config. */
    public static final String PROVIDER_ID = "knobby-mcp-tenant-picker";

    private static final String DISPLAY_TYPE = "Knobby MCP Tenant Picker";
    private static final String REFERENCE_CATEGORY = "knobby-mcp";

    private static final String HELP_TEXT =
            "Redirects MCP-client auth flows to Knobby web for tenant picker "
                    + "and consent. Required final step of "
                    + "browser-mcp-tenant-pick flow. Configure knobby.web.host "
                    + "per realm.";

    private static final Requirement[] REQUIREMENT_CHOICES =
            new Requirement[] { Requirement.REQUIRED };

    private static final ProviderConfigProperty WEB_HOST_PROPERTY =
            new ProviderConfigProperty(
                    McpTenantPickerAuthenticator.CONFIG_KEY_WEB_HOST,
                    "Knobby web host",
                    "Hostname Knobby web serves /mcp/consent at, for this realm. "
                            + "No scheme, no trailing slash. "
                            + "E.g., 'prod.knobby.io' in knobby-prod, "
                            + "'dev.knobby.io' in knobby-dev. "
                            + "The Authenticator constructs "
                            + "https://<host>/mcp/consent?token=...",
                    ProviderConfigProperty.STRING_TYPE,
                    null);

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES =
            List.of(WEB_HOST_PROPERTY);

    private HandoffTokenSigner signer;

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
    public String getReferenceCategory()
    {
        return REFERENCE_CATEGORY;
    }

    @Override
    public boolean isConfigurable()
    {
        return true;
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties()
    {
        return CONFIG_PROPERTIES;
    }

    @Override
    public Requirement[] getRequirementChoices()
    {
        return REQUIREMENT_CHOICES.clone();
    }

    @Override
    public boolean isUserSetupAllowed()
    {
        return false;
    }

    @Override
    public String getHelpText()
    {
        return HELP_TEXT;
    }

    @Override
    public Authenticator create(KeycloakSession session)
    {
        return new McpTenantPickerAuthenticator(signer);
    }

    @Override
    public void init(Config.Scope config)
    {
        McpSpiConfig spiConfig = new McpSpiConfig();
        this.signer = new HandoffTokenSigner(spiConfig);

        Set<String> realms = new TreeSet<>(spiConfig.realmsWithKeysConfigured());
        if (realms.isEmpty())
        {
            log.warnf("Loaded MCP SPI provider %s. "
                    + "No HMAC keys configured for any realm — "
                    + "the SPI will fail any MCP login flow until "
                    + "KNOBBY_MCP_HANDOFF_HMAC_KEY__<R> env vars are set.",
                    PROVIDER_ID);
        }
        else
        {
            log.infof("Loaded MCP SPI provider %s. "
                    + "HMAC keys configured for realms: %s",
                    PROVIDER_ID, realms);
        }
    }

    @Override
    public void postInit(KeycloakSessionFactory factory)
    {
        // No-op.
    }

    @Override
    public void close()
    {
        // No-op.
    }
}
