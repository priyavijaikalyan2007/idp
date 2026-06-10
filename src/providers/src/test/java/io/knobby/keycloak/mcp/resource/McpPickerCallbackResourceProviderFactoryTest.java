/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 3abebe29-355e-454e-8ef5-52a73876fde6
 * Repository: knobby/idp
 * Created: 2026-06-08
 */
package io.knobby.keycloak.mcp.resource;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import org.keycloak.models.KeycloakSession;
import org.keycloak.services.resource.RealmResourceProvider;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class McpPickerCallbackResourceProviderFactoryTest
{
    @Mock private KeycloakSession session;

    private McpPickerCallbackResourceProviderFactory factory;

    @BeforeEach
    void setUp()
    {
        factory = new McpPickerCallbackResourceProviderFactory();
    }

    @Test
    void getId_returnsStableProviderId()
    {
        assertEquals("mcp-picker-callback", factory.getId());
        assertEquals(McpPickerCallbackResourceProviderFactory.PROVIDER_ID,
                factory.getId());
    }

    @Test
    void create_afterInit_returnsResourceProvider()
    {
        factory.init(null);
        RealmResourceProvider provider = factory.create(session);
        assertNotNull(provider);
        assertTrue(provider instanceof McpPickerCallbackResourceProvider);
    }

    @Test
    void init_isIdempotent()
    {
        // Calling init twice must not throw and must yield a working create().
        factory.init(null);
        factory.init(null);
        assertNotNull(factory.create(session));
    }

    @Test
    void close_doesNotThrow()
    {
        factory.init(null);
        factory.close();
    }

    @Test
    void postInit_doesNotThrow()
    {
        factory.init(null);
        factory.postInit(null);
    }
}
