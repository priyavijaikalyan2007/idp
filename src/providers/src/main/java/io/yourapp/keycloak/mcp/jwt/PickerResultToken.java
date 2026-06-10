/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: e1105de2-b2b2-4de0-9316-d53834a65528
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: PickerResultToken
 * 📜 PURPOSE: Immutable picker-result JWT payload returned by YourApp web to
 *             the Keycloak SPI's mcp-picker-callback endpoint. Carries the
 *             chosen tenant, granted scopes, correlation back to the
 *             picker-request (jti, user_sub_echo), and the Keycloak auth-session
 *             correlation fields (kc_client_id, kc_tab_id, auth_session_id)
 *             needed for the callback to re-find and resume the suspended
 *             flow on the same browser.
 * 🔗 RELATES: [[PickerRequestToken]], [[HandoffTokenValidator]],
 *             [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [YourApp web /mcp/consent] -> [302 to /realms/{r}/mcp-picker-callback]
 *         -> [HandoffTokenValidator.validatePickerResult]
 * 🛡️ SECURITY: HS256-verified; replay-protected via jti; 1-min TTL;
 *              user_sub_echo cross-checked against current auth session user;
 *              kc_* correlation fields are HMAC-protected (not query-param
 *              tamperable).
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.jwt;

import java.util.List;

import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Picker-result JWT payload. Snake_case claim names on the wire (ADR-005);
 * camelCase Java fields bridged by Jackson {@link JsonProperty}.
 *
 * <p>The three {@code kc_*} fields (and {@code auth_session_id}) echo their
 * values from the corresponding {@link PickerRequestToken}. YourApp web is
 * responsible for copying them through unchanged.
 *
 * <p>See {@code keycloak.spi.mcp.md} §6.2 and the Slice 4 design in
 * {@code keycloak.spi.mcp.status.md} §3.5.
 */
public final class PickerResultToken
{
    private final String iss;
    private final String aud;
    private final String pickerRequestJti;
    private final String userSubEcho;
    private final String chosenTenantId;
    private final List<String> grantedScopes;
    private final String oauthState;
    private final String authSessionId;
    private final String kcClientId;
    private final String kcTabId;
    private final String nonce;
    private final String jti;
    private final long iat;
    private final long exp;

    @JsonCreator
    public PickerResultToken(
            @JsonProperty("iss") String iss,
            @JsonProperty("aud") String aud,
            @JsonProperty("picker_request_jti") String pickerRequestJti,
            @JsonProperty("user_sub_echo") String userSubEcho,
            @JsonProperty("chosen_tenant_id") String chosenTenantId,
            @JsonProperty("granted_scopes") List<String> grantedScopes,
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
        this.pickerRequestJti = pickerRequestJti;
        this.userSubEcho = userSubEcho;
        this.chosenTenantId = chosenTenantId;
        this.grantedScopes = grantedScopes == null
                ? List.of()
                : List.copyOf(grantedScopes);
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
    @JsonProperty("picker_request_jti") public String getPickerRequestJti() { return pickerRequestJti; }
    @JsonProperty("user_sub_echo") public String getUserSubEcho() { return userSubEcho; }
    @JsonProperty("chosen_tenant_id") public String getChosenTenantId() { return chosenTenantId; }
    @JsonProperty("granted_scopes") public List<String> getGrantedScopes() { return grantedScopes; }
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
        private String pickerRequestJti;
        private String userSubEcho;
        private String chosenTenantId;
        private List<String> grantedScopes;
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
        public Builder pickerRequestJti(String v) { this.pickerRequestJti = v; return this; }
        public Builder userSubEcho(String v) { this.userSubEcho = v; return this; }
        public Builder chosenTenantId(String v) { this.chosenTenantId = v; return this; }
        public Builder grantedScopes(List<String> v) { this.grantedScopes = v; return this; }
        public Builder oauthState(String v) { this.oauthState = v; return this; }
        public Builder authSessionId(String v) { this.authSessionId = v; return this; }
        public Builder kcClientId(String v) { this.kcClientId = v; return this; }
        public Builder kcTabId(String v) { this.kcTabId = v; return this; }
        public Builder nonce(String v) { this.nonce = v; return this; }
        public Builder jti(String v) { this.jti = v; return this; }
        public Builder iat(long v) { this.iat = v; return this; }
        public Builder exp(long v) { this.exp = v; return this; }

        public PickerResultToken build()
        {
            requireString("iss", iss);
            requireString("aud", aud);
            requireString("picker_request_jti", pickerRequestJti);
            requireString("user_sub_echo", userSubEcho);
            requireString("chosen_tenant_id", chosenTenantId);
            // oauth_state echoes the request's value; null when the request omitted it.
            requireString("auth_session_id", authSessionId);
            requireString("kc_client_id", kcClientId);
            requireString("kc_tab_id", kcTabId);
            requireString("nonce", nonce);
            requireString("jti", jti);
            requirePositive("iat", iat);
            requirePositive("exp", exp);
            return new PickerResultToken(iss, aud, pickerRequestJti, userSubEcho,
                    chosenTenantId, grantedScopes, oauthState, authSessionId,
                    kcClientId, kcTabId, nonce, jti, iat, exp);
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
