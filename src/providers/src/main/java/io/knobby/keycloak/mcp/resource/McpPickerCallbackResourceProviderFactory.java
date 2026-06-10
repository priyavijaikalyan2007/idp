/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 5c639ba2-8efc-4f12-905b-d11a5d8571f4
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpPickerCallbackResourceProviderFactory
 * 📜 PURPOSE: Keycloak SPI factory for McpPickerCallbackResourceProvider.
 *             Mounts the callback at /realms/{realm}/mcp-picker-callback.
 *             Owns the singleton McpSpiConfig + ReplayCache + HandoffToken-
 *             Validator (per-realm key cache + replay defence survive across
 *             requests).
 * 🔗 RELATES: [[McpPickerCallbackResourceProvider]], [[McpSpiConfig]],
 *             [[HandoffTokenValidator]], [[ReplayCache]]
 * ⚡ FLOW: [Keycloak SPI loader] -> [this.init / create]
 *         -> [Resource provider instances]
 * 🛡️ SECURITY: PROVIDER_ID component appears in the URL — keep stable; any
 *              change breaks Knobby web's redirect target.
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.resource;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

import io.knobby.keycloak.mcp.config.McpSpiConfig;
import io.knobby.keycloak.mcp.jwt.HandoffTokenValidator;
import io.knobby.keycloak.mcp.util.ReplayCache;

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
        ReplayCache replayCache = new ReplayCache();
        this.validator = new HandoffTokenValidator(spiConfig, replayCache);
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
