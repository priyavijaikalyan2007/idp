/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 49940025-3f51-4eb7-b450-5d10d822f867
 * Repository: yourapp/idp
 * Created: 2026-07-06
 */
package io.yourapp.keycloak.mcp.clientreg;

import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.MockedStatic;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import org.keycloak.common.util.MultivaluedHashMap;
import org.keycloak.component.ComponentModel;
import org.keycloak.models.AuthenticationFlowBindings;
import org.keycloak.models.AuthenticationFlowModel;
import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientScopeModel;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.representations.idm.ClientRepresentation;
import org.keycloak.services.clientregistration.ClientRegistrationContext;
import org.keycloak.services.clientregistration.policy.ClientRegistrationPolicyException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for the atomic MCP-marking behaviour of the CRP (spec §5.8).
 *
 * <p>The realm-model lookup {@code KeycloakModelUtils.getClientScopeByName} is a
 * static call, so each test opens a {@link MockedStatic} scope over it.
 */
@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class McpClientRegistrationPolicyTest
{
    private static final String FLOW_ID = "flow-id-mcp-123";

    @Mock private KeycloakSession session;
    @Mock private KeycloakContext keycloakContext;
    @Mock private RealmModel realm;
    @Mock private ClientModel client;
    @Mock private ComponentModel componentModel;
    @Mock private ClientRegistrationContext regContext;
    @Mock private AuthenticationFlowModel flowModel;

    private McpClientRegistrationPolicy policy;

    @BeforeEach
    void setUp()
    {
        when(session.getContext()).thenReturn(keycloakContext);
        when(keycloakContext.getRealm()).thenReturn(realm);

        // Default: no admin overrides configured → policy uses its fallbacks.
        when(componentModel.getConfig()).thenReturn(new MultivaluedHashMap<>());
        when(componentModel.get(eq(McpClientRegistrationPolicyFactory.CFG_FLOW_ALIAS), anyString()))
                .thenAnswer(inv -> inv.getArgument(1));

        when(realm.getFlowByAlias(McpClientRegistrationPolicyFactory.FLOW_ALIAS_FALLBACK))
                .thenReturn(flowModel);
        when(flowModel.getId()).thenReturn(FLOW_ID);

        policy = new McpClientRegistrationPolicy(session, componentModel);
    }

    /** Every configured scope name resolves to a distinct mock scope. */
    private MockedStatic<KeycloakModelUtils> stubAllScopesResolve()
    {
        MockedStatic<KeycloakModelUtils> mocked = mockStatic(KeycloakModelUtils.class);
        mocked.when(() -> KeycloakModelUtils.getClientScopeByName(eq(realm), anyString()))
                .thenAnswer(inv ->
                {
                    ClientScopeModel scope = org.mockito.Mockito.mock(ClientScopeModel.class);
                    when(scope.getName()).thenReturn(inv.getArgument(1));
                    return scope;
                });
        return mocked;
    }

    // ------------------------------------------------------------ marking

    @Test
    void afterRegister_marksClientWithMcpAttribute()
    {
        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        verify(client).setAttribute(
                McpClientRegistrationPolicy.MCP_ATTRIBUTE,
                McpClientRegistrationPolicy.MCP_ATTRIBUTE_VALUE);
    }

    @Test
    void afterRegister_suppressesBuiltInConsent()
    {
        // The yourapp /mcp/consent wizard is the sole consent surface; Keycloak's
        // built-in OAUTH_GRANT screen must be off for MCP clients (ERRATA-006).
        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        verify(client).setConsentRequired(false);
    }

    // ------------------------------------------------------- scope assignment

    @Test
    void afterRegister_assignsFallbackDefaultScopesAsDefault()
    {
        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        ArgumentCaptor<ClientScopeModel> scopeCaptor =
                ArgumentCaptor.forClass(ClientScopeModel.class);
        ArgumentCaptor<Boolean> defaultCaptor = ArgumentCaptor.forClass(Boolean.class);
        verify(client, org.mockito.Mockito.atLeastOnce())
                .addClientScope(scopeCaptor.capture(), defaultCaptor.capture());

        Map<String, Boolean> assignedByName = new java.util.HashMap<>();
        List<ClientScopeModel> scopes = scopeCaptor.getAllValues();
        List<Boolean> flags = defaultCaptor.getAllValues();
        for (int i = 0; i < scopes.size(); i++)
        {
            assignedByName.put(scopes.get(i).getName(), flags.get(i));
        }

        for (String name : McpClientRegistrationPolicyFactory.DEFAULT_SCOPES_FALLBACK)
        {
            assertTrue(assignedByName.containsKey(name), "missing default scope " + name);
            assertEquals(Boolean.TRUE, assignedByName.get(name),
                    name + " must be assigned as a DEFAULT scope");
        }
    }

    @Test
    void afterRegister_assignsFallbackOptionalScopesAsOptional()
    {
        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        ArgumentCaptor<ClientScopeModel> scopeCaptor =
                ArgumentCaptor.forClass(ClientScopeModel.class);
        ArgumentCaptor<Boolean> defaultCaptor = ArgumentCaptor.forClass(Boolean.class);
        verify(client, org.mockito.Mockito.atLeastOnce())
                .addClientScope(scopeCaptor.capture(), defaultCaptor.capture());

        List<ClientScopeModel> scopes = scopeCaptor.getAllValues();
        List<Boolean> flags = defaultCaptor.getAllValues();
        for (int i = 0; i < scopes.size(); i++)
        {
            if (McpClientRegistrationPolicyFactory.OPTIONAL_SCOPES_FALLBACK
                    .contains(scopes.get(i).getName()))
            {
                assertEquals(Boolean.FALSE, flags.get(i),
                        scopes.get(i).getName() + " must be assigned as OPTIONAL");
            }
        }
    }

    @Test
    void afterRegister_promotesPreboundScope_removesBindingBeforeAdding()
    {
        // A real OIDC DCR pre-binds the requested `scope` values as OPTIONAL client
        // scopes BEFORE this policy runs. ClientModel.addClientScope is a no-op when
        // a binding already exists, so it will NOT promote optional -> default. The
        // policy must remove any existing binding first (ERRATA-006).
        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        int expectedCount = McpClientRegistrationPolicyFactory.DEFAULT_SCOPES_FALLBACK.size()
                + McpClientRegistrationPolicyFactory.OPTIONAL_SCOPES_FALLBACK.size();
        ArgumentCaptor<ClientScopeModel> removed =
                ArgumentCaptor.forClass(ClientScopeModel.class);
        verify(client, org.mockito.Mockito.times(expectedCount))
                .removeClientScope(removed.capture());

        java.util.Set<String> removedNames = removed.getAllValues().stream()
                .map(ClientScopeModel::getName)
                .collect(java.util.stream.Collectors.toSet());
        for (String name : McpClientRegistrationPolicyFactory.DEFAULT_SCOPES_FALLBACK)
        {
            assertTrue(removedNames.contains(name),
                    "default scope " + name + " must be removed before (re)adding");
        }

        // Ordering: a remove precedes an add (the loop does remove;add per scope).
        org.mockito.InOrder inOrder = org.mockito.Mockito.inOrder(client);
        inOrder.verify(client).removeClientScope(org.mockito.ArgumentMatchers.any());
        inOrder.verify(client).addClientScope(
                org.mockito.ArgumentMatchers.any(),
                org.mockito.ArgumentMatchers.anyBoolean());
    }

    // --------------------------------------------------------- flow binding

    @Test
    void afterRegister_bindsBrowserFlowOverrideToResolvedFlowId()
    {
        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        verify(client).setAuthenticationFlowBindingOverride(
                AuthenticationFlowBindings.BROWSER_BINDING, FLOW_ID);
    }

    // ----------------------------------------------- atomic failure: bad scope

    @Test
    void afterRegister_missingRequiredScope_throwsPolicyException()
    {
        try (MockedStatic<KeycloakModelUtils> mocked = mockStatic(KeycloakModelUtils.class))
        {
            // First scope resolves; a later one is missing → registration must roll back.
            mocked.when(() -> KeycloakModelUtils.getClientScopeByName(eq(realm), anyString()))
                    .thenReturn(null);

            assertThrows(ClientRegistrationPolicyException.class,
                    () -> policy.afterRegister(regContext, client));
        }
    }

    @Test
    void afterRegister_missingFlow_throwsPolicyException()
    {
        when(realm.getFlowByAlias(McpClientRegistrationPolicyFactory.FLOW_ALIAS_FALLBACK))
                .thenReturn(null);

        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            assertThrows(ClientRegistrationPolicyException.class,
                    () -> policy.afterRegister(regContext, client));
        }
    }

    // -------------------------------------------------- admin config override

    @Test
    void afterRegister_usesConfiguredScopeListWhenPresent()
    {
        MultivaluedHashMap<String, String> config = new MultivaluedHashMap<>();
        config.add(McpClientRegistrationPolicyFactory.CFG_DEFAULT_SCOPES, "custom-scope");
        when(componentModel.getConfig()).thenReturn(config);

        try (MockedStatic<KeycloakModelUtils> ignored = stubAllScopesResolve())
        {
            policy.afterRegister(regContext, client);
        }

        ArgumentCaptor<ClientScopeModel> scopeCaptor =
                ArgumentCaptor.forClass(ClientScopeModel.class);
        verify(client, org.mockito.Mockito.atLeastOnce())
                .addClientScope(scopeCaptor.capture(), eq(true));

        boolean hasCustom = scopeCaptor.getAllValues().stream()
                .anyMatch(s -> "custom-scope".equals(s.getName()));
        assertTrue(hasCustom, "configured override scope must be assigned");

        // And the fallback default scopes must NOT be used when an override is present.
        boolean hasFallback = scopeCaptor.getAllValues().stream()
                .anyMatch(s -> "mcp-default".equals(s.getName()));
        assertTrue(!hasFallback, "fallback scopes must be ignored when config overrides them");
    }

    // --------------------------------------- B1: allowed-grant-types guard

    @Test
    void beforeRegister_authCodeOnly_passes()
    {
        // authorization_code (+ refresh) — the only permitted shape. No throw.
        ClientRepresentation rep = new ClientRepresentation();
        rep.setStandardFlowEnabled(true);
        when(regContext.getClient()).thenReturn(rep);

        policy.beforeRegister(regContext); // must not throw
    }

    @Test
    void beforeRegister_nullClient_doesNotThrow()
    {
        when(regContext.getClient()).thenReturn(null);
        policy.beforeRegister(regContext);
    }

    @Test
    void beforeRegister_directAccessGrants_rejected()
    {
        // ROPC — the critical bypass: tokens without the browser flow.
        ClientRepresentation rep = new ClientRepresentation();
        rep.setDirectAccessGrantsEnabled(true);
        when(regContext.getClient()).thenReturn(rep);

        assertThrows(ClientRegistrationPolicyException.class,
                () -> policy.beforeRegister(regContext));
    }

    @Test
    void beforeRegister_implicitFlow_rejected()
    {
        ClientRepresentation rep = new ClientRepresentation();
        rep.setImplicitFlowEnabled(true);
        when(regContext.getClient()).thenReturn(rep);

        assertThrows(ClientRegistrationPolicyException.class,
                () -> policy.beforeRegister(regContext));
    }

    @Test
    void beforeRegister_serviceAccounts_rejected()
    {
        ClientRepresentation rep = new ClientRepresentation();
        rep.setServiceAccountsEnabled(true);
        when(regContext.getClient()).thenReturn(rep);

        assertThrows(ClientRegistrationPolicyException.class,
                () -> policy.beforeRegister(regContext));
    }

    @Test
    void beforeRegister_deviceGrant_rejected()
    {
        ClientRepresentation rep = new ClientRepresentation();
        rep.setAttributes(java.util.Map.of(
                McpClientRegistrationPolicy.ATTR_DEVICE_GRANT, "true"));
        when(regContext.getClient()).thenReturn(rep);

        assertThrows(ClientRegistrationPolicyException.class,
                () -> policy.beforeRegister(regContext));
    }

    @Test
    void beforeRegister_cibaGrant_rejected()
    {
        ClientRepresentation rep = new ClientRepresentation();
        rep.setAttributes(java.util.Map.of(
                McpClientRegistrationPolicy.ATTR_CIBA_GRANT, "true"));
        when(regContext.getClient()).thenReturn(rep);

        assertThrows(ClientRegistrationPolicyException.class,
                () -> policy.beforeRegister(regContext));
    }

    @Test
    void beforeUpdate_directAccessGrants_rejected()
    {
        // The guard also runs on update — a client can't widen its grants later.
        ClientRepresentation rep = new ClientRepresentation();
        rep.setDirectAccessGrantsEnabled(true);
        when(regContext.getClient()).thenReturn(rep);

        assertThrows(ClientRegistrationPolicyException.class,
                () -> policy.beforeUpdate(regContext, client));
    }

    // ------------------------------------------------------- no-op lifecycle

    @Test
    void afterUpdate_isNoOp_doesNotTouchClient()
    {
        policy.afterUpdate(regContext, client);
        verify(client, never()).setAttribute(anyString(), anyString());
        verify(client, never()).addClientScope(any(), org.mockito.ArgumentMatchers.anyBoolean());
        verify(client, never()).removeClientScope(any());
        verify(client, never()).setConsentRequired(org.mockito.ArgumentMatchers.anyBoolean());
    }

    @Test
    void close_doesNotThrow()
    {
        policy.close();
    }
}
