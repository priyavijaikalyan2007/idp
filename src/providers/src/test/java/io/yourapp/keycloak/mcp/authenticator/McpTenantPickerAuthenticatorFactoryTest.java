/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 252afdce-ca05-4613-8a3b-424fd667bacc
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.authenticator;

import java.util.List;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import org.keycloak.authentication.Authenticator;
import org.keycloak.models.AuthenticationExecutionModel.Requirement;
import org.keycloak.models.KeycloakSession;
import org.keycloak.provider.ProviderConfigProperty;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class McpTenantPickerAuthenticatorFactoryTest
{
    @Mock private KeycloakSession session;

    private McpTenantPickerAuthenticatorFactory factory;

    @BeforeEach
    void setUp()
    {
        factory = new McpTenantPickerAuthenticatorFactory();
    }

    @Test
    void getId_returnsStableProviderId()
    {
        assertEquals("yourapp-mcp-tenant-picker", factory.getId());
        assertEquals(McpTenantPickerAuthenticatorFactory.PROVIDER_ID, factory.getId());
    }

    @Test
    void getDisplayType_isAdminConsoleLabel()
    {
        assertEquals("YourApp MCP Tenant Picker", factory.getDisplayType());
    }

    @Test
    void getReferenceCategory_isYourAppMcp()
    {
        assertEquals("yourapp-mcp", factory.getReferenceCategory());
    }

    @Test
    void isConfigurable_isTrue()
    {
        assertTrue(factory.isConfigurable(),
                "must be configurable to expose yourapp.web.host per realm");
    }

    @Test
    void getConfigProperties_containsYourAppWebHost()
    {
        List<ProviderConfigProperty> properties = factory.getConfigProperties();
        assertEquals(1, properties.size());
        ProviderConfigProperty webHost = properties.get(0);
        assertEquals(McpTenantPickerAuthenticator.CONFIG_KEY_WEB_HOST,
                webHost.getName());
        assertEquals(ProviderConfigProperty.STRING_TYPE, webHost.getType());
        assertEquals("YourApp web host", webHost.getLabel());
        assertNotNull(webHost.getHelpText());
    }

    @Test
    void getRequirementChoices_containsOnlyRequired()
    {
        Requirement[] choices = factory.getRequirementChoices();
        assertEquals(1, choices.length);
        assertEquals(Requirement.REQUIRED, choices[0]);
    }

    @Test
    void getRequirementChoices_returnsDefensiveCopy()
    {
        Requirement[] first = factory.getRequirementChoices();
        Requirement[] second = factory.getRequirementChoices();
        assertFalse(first == second, "must return a copy so callers cannot mutate state");
    }

    @Test
    void isUserSetupAllowed_isFalse()
    {
        assertFalse(factory.isUserSetupAllowed());
    }

    @Test
    void getHelpText_mentionsYourAppWebHostConfig()
    {
        String help = factory.getHelpText();
        assertNotNull(help);
        assertTrue(help.contains("yourapp.web.host"),
                "help text must mention the config property: " + help);
    }

    @Test
    void create_afterInit_returnsAuthenticatorInstance()
    {
        factory.init(null);
        Authenticator authenticator = factory.create(session);
        assertNotNull(authenticator);
        assertTrue(authenticator instanceof McpTenantPickerAuthenticator);
    }

    @Test
    void init_withNoEnvKeys_logsWarningButDoesNotThrow()
    {
        // No env vars are configured for keys in this test JVM; init must not throw.
        factory.init(null);
        // Calling init again is idempotent (rebuilds the cached signer).
        factory.init(null);
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
