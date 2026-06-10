/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: ec6ca801-55d9-4918-bf4b-da2c83ca5b8e
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: PickerRequestToken
 * 📜 PURPOSE: Immutable picker-request JWT payload sent from the Keycloak SPI
 *             to Knobby web's /mcp/consent endpoint. Carries the user/client/
 *             requested-scopes/state plus the Keycloak auth-session correlation
 *             fields (kc_client_id, kc_tab_id, auth_session_id) needed to
 *             resume the suspended flow on the callback.
 * 🔗 RELATES: [[PickerResultToken]], [[HandoffTokenSigner]]
 * ⚡ FLOW: [McpTenantPickerAuthenticator] -> [HandoffTokenSigner.sign] -> [302 to Knobby web]
 * 🛡️ SECURITY: HS256-signed; replay-protected via jti; 5-min TTL.
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.jwt;

import java.util.List;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Picker-request JWT payload. Snake_case claim names on the wire (ADR-005);
 * camelCase Java fields bridged by Jackson {@link JsonProperty}.
 *
 * <p>Constructed in production via {@link #builder()}. Jackson deserialises
 * through the {@link JsonCreator}-annotated constructor; this supports
 * round-trip tests but is not used at runtime (the SPI never receives a
 * picker-request token — it only sends them).
 *
 * <p>See {@code keycloak.spi.mcp.md} §6.1.
 */
public final class PickerRequestToken
{
    private final String iss;
    private final String aud;
    private final String sub;
    private final String knobbySub;
    private final String mcpClientId;
    private final List<String> mcpRequestedScopes;
    private final String oauthState;
    private final String authSessionId;
    private final String kcClientId;
    private final String kcTabId;
    private final String nonce;
    private final String jti;
    private final long iat;
    private final long exp;

    @JsonCreator
    public PickerRequestToken(
            @JsonProperty("iss") String iss,
            @JsonProperty("aud") String aud,
            @JsonProperty("sub") String sub,
            @JsonProperty("knobby_sub") String knobbySub,
            @JsonProperty("mcp_client_id") String mcpClientId,
            @JsonProperty("mcp_requested_scopes") List<String> mcpRequestedScopes,
            @JsonProperty("oauth_state") String oauthState,
            @JsonProperty("auth_session_id") String authSessionId,
            @JsonProperty("kc_client_id") String kcClientId,
            @JsonProperty("kc_tab_id") String kcTabId,
            @JsonProperty("nonce") String nonce,
            @JsonProperty("jti") String jti,
            @JsonProperty("iat") long iat,
            @JsonProperty("exp") long exp)
    {
        this.iss = iss;
        this.aud = aud;
        this.sub = sub;
        this.knobbySub = knobbySub;
        this.mcpClientId = mcpClientId;
        this.mcpRequestedScopes = mcpRequestedScopes == null
                ? List.of()
                : List.copyOf(mcpRequestedScopes);
        this.oauthState = oauthState;
        this.authSessionId = authSessionId;
        this.kcClientId = kcClientId;
        this.kcTabId = kcTabId;
        this.nonce = nonce;
        this.jti = jti;
        this.iat = iat;
        this.exp = exp;
    }

    @JsonProperty("iss") public String getIss() { return iss; }
    @JsonProperty("aud") public String getAud() { return aud; }
    @JsonProperty("sub") public String getSub() { return sub; }
    @JsonProperty("knobby_sub") public String getKnobbySub() { return knobbySub; }
    @JsonProperty("mcp_client_id") public String getMcpClientId() { return mcpClientId; }
    @JsonProperty("mcp_requested_scopes") public List<String> getMcpRequestedScopes() { return mcpRequestedScopes; }
    @JsonProperty("oauth_state") public String getOauthState() { return oauthState; }
    @JsonProperty("auth_session_id") public String getAuthSessionId() { return authSessionId; }
    @JsonProperty("kc_client_id") public String getKcClientId() { return kcClientId; }
    @JsonProperty("kc_tab_id") public String getKcTabId() { return kcTabId; }
    @JsonProperty("nonce") public String getNonce() { return nonce; }
    @JsonProperty("jti") public String getJti() { return jti; }
    @JsonProperty("iat") public long getIat() { return iat; }
    @JsonProperty("exp") public long getExp() { return exp; }

    public static Builder builder()
    {
        return new Builder();
    }

    /** Fluent builder with required-field validation in {@link #build()}. */
    public static final class Builder
    {
        private String iss;
        private String aud;
        private String sub;
        private String knobbySub;
        private String mcpClientId;
        private List<String> mcpRequestedScopes;
        private String oauthState;
        private String authSessionId;
        private String kcClientId;
        private String kcTabId;
        private String nonce;
        private String jti;
        private long iat;
        private long exp;

        public Builder iss(String v) { this.iss = v; return this; }
        public Builder aud(String v) { this.aud = v; return this; }
        public Builder sub(String v) { this.sub = v; return this; }
        public Builder knobbySub(String v) { this.knobbySub = v; return this; }
        public Builder mcpClientId(String v) { this.mcpClientId = v; return this; }
        public Builder mcpRequestedScopes(List<String> v) { this.mcpRequestedScopes = v; return this; }
        public Builder oauthState(String v) { this.oauthState = v; return this; }
        public Builder authSessionId(String v) { this.authSessionId = v; return this; }
        public Builder kcClientId(String v) { this.kcClientId = v; return this; }
        public Builder kcTabId(String v) { this.kcTabId = v; return this; }
        public Builder nonce(String v) { this.nonce = v; return this; }
        public Builder jti(String v) { this.jti = v; return this; }
        public Builder iat(long v) { this.iat = v; return this; }
        public Builder exp(long v) { this.exp = v; return this; }

        public PickerRequestToken build()
        {
            requireString("iss", iss);
            requireString("aud", aud);
            requireString("sub", sub);
            requireString("knobby_sub", knobbySub);
            requireString("mcp_client_id", mcpClientId);
            // oauth_state is OPTIONAL per OAuth 2.1 — clients may omit `state`.
            // Skip required-string check; the token field tolerates null/empty.
            requireString("auth_session_id", authSessionId);
            requireString("kc_client_id", kcClientId);
            requireString("kc_tab_id", kcTabId);
            requireString("nonce", nonce);
            requireString("jti", jti);
            requirePositive("iat", iat);
            requirePositive("exp", exp);
            return new PickerRequestToken(iss, aud, sub, knobbySub, mcpClientId,
                    mcpRequestedScopes, oauthState, authSessionId, kcClientId,
                    kcTabId, nonce, jti, iat, exp);
        }

        private static void requireString(String name, String value)
        {
            if (value == null || value.isBlank())
            {
                throw new IllegalStateException(
                        "Required claim '" + name + "' is missing");
            }
        }

        private static void requirePositive(String name, long value)
        {
            if (value <= 0)
            {
                throw new IllegalStateException(
                        "Required claim '" + name + "' must be > 0, was " + value);
            }
        }
    }
}
