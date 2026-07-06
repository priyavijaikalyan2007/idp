/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 78314acc-9d0f-4226-96ef-ab792570b5c5
 * Repository: knobby/idp
 * Created: 2026-07-06
 */
package io.knobby.keycloak.mcp.clientreg;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import org.keycloak.component.ComponentModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

@ExtendWith(MockitoExtension.class)
class McpClientRegistrationPolicyFactoryTest
{
    @Mock private KeycloakSession session;
    @Mock private ComponentModel componentModel;

    private final McpClientRegistrationPolicyFactory factory =
            new McpClientRegistrationPolicyFactory();

    @Test
    void getId_returnsStableProviderId()
    {
        assertEquals("knobby-mcp-registration", factory.getId());
        assertEquals(McpClientRegistrationPolicyFactory.PROVIDER_ID, factory.getId());
    }

    @Test
    void create_returnsMcpPolicyInstance()
    {
        ClientRegistrationPolicy policy = factory.create(session, componentModel);
        assertNotNull(policy);
        assertInstanceOf(McpClientRegistrationPolicy.class, policy);
    }

    @Test
    void getHelpText_isNonBlank()
    {
        assertNotNull(factory.getHelpText());
        assertFalse(factory.getHelpText().isBlank());
    }

    @Test
    void getConfigProperties_exposesTheThreeTunables()
    {
        assertConfigKeys(factory.getConfigProperties());
    }

    @Test
    void getConfigPropertiesWithSession_exposesTheThreeTunables()
    {
        assertConfigKeys(factory.getConfigProperties(session));
    }

    private static void assertConfigKeys(List<ProviderConfigProperty> props)
    {
        assertNotNull(props);
        List<String> names = props.stream().map(ProviderConfigProperty::getName).toList();
        assertTrue(names.contains(McpClientRegistrationPolicyFactory.CFG_DEFAULT_SCOPES),
                "default-scopes config property expected");
        assertTrue(names.contains(McpClientRegistrationPolicyFactory.CFG_OPTIONAL_SCOPES),
                "optional-scopes config property expected");
        assertTrue(names.contains(McpClientRegistrationPolicyFactory.CFG_FLOW_ALIAS),
                "flow-alias config property expected");
    }
}
