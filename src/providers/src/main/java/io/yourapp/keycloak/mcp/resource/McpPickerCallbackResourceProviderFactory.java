/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 5c639ba2-8efc-4f12-905b-d11a5d8571f4
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpPickerCallbackResourceProviderFactory
 * 📜 PURPOSE: Keycloak SPI factory for McpPickerCallbackResourceProvider.
 *             Mounts the callback at /realms/{realm}/mcp-picker-callback.
 *             Owns the singleton McpSpiConfig + HandoffTokenValidator (per-realm
 *             key cache survives across requests). Replay defence is per-request
 *             via Keycloak's SingleUseObjectProvider (RT-010), not owned here.
 * 🔗 RELATES: [[McpPickerCallbackResourceProvider]], [[McpSpiConfig]],
 *             [[HandoffTokenValidator]]
 * ⚡ FLOW: [Keycloak SPI loader] -> [this.init / create]
 *         -> [Resource provider instances]
 * 🛡️ SECURITY: PROVIDER_ID component appears in the URL — keep stable; any
 *              change breaks YourApp web's redirect target.
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.resource;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

import io.yourapp.keycloak.mcp.config.McpSpiConfig;
import io.yourapp.keycloak.mcp.jwt.HandoffTokenValidator;

/**
 * Single instance per Keycloak JVM. Resulting URL:
 * {@code /realms/{realm}/mcp-picker-callback}.
 *
 * <p>See {@code keycloak.spi.mcp.md} §5.4.
 */
public final class McpPickerCallbackResourceProviderFactory
        implements RealmResourceProviderFactory
{
    /** URL path component for the callback. Stable; do not change. */
    public static final String PROVIDER_ID = "mcp-picker-callback";

    private HandoffTokenValidator validator;

    @Override
    public String getId()
    {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session)
    {
        return new McpPickerCallbackResourceProvider(session, validator);
    }

    @Override
    public void init(Config.Scope config)
    {
        McpSpiConfig spiConfig = new McpSpiConfig();
        // RT-010: replay defense is the per-request ReplayGuard the provider builds
        // from session.singleUseObjects() (distributed) — no in-memory cache here.
        this.validator = new HandoffTokenValidator(spiConfig);
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
