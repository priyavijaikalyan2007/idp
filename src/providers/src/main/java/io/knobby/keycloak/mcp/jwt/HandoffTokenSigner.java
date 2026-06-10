/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 5409c39f-a9ef-4d67-86b2-2094e0ab7489
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: HandoffTokenSigner
 * 📜 PURPOSE: Signs picker-request (and reusable for other) POJOs into HS256
 *             JWTs using the per-realm HMAC key from McpSpiConfig.
 * 🔗 RELATES: [[McpSpiConfig]], [[HandoffTokenValidator]],
 *             [[McpTenantPickerAuthenticator]]
 * ⚡ FLOW: [McpTenantPickerAuthenticator] -> [this.sign] -> [Keycloak JWSBuilder.hmac256]
 * 🛡️ SECURITY: Caches decoded HMAC key bytes per realm. Key bytes never leave
 *              this instance. Failures (missing/malformed key) propagate as
 *              McpSpiConfigException for upstream literate-error handling.
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.jwt;

import java.util.Base64;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

import org.keycloak.crypto.KeyWrapper;
import org.keycloak.crypto.MacSignatureSignerContext;
import org.keycloak.crypto.SignatureSignerContext;
import org.keycloak.jose.jws.JWSBuilder;

import io.knobby.keycloak.mcp.config.McpSpiConfig;

/**
 * Stateless signer (modulo the per-realm key cache). One instance per JVM is
 * sufficient; both authenticator instances and resource-provider instances may
 * share one. Thread-safe via {@link ConcurrentMap}.
 *
 * <p>Sign always uses the realm's current HMAC key. Validation against the
 * previous key (for rotation overlap) is the validator's concern; the signer
 * always emits with current.
 *
 * <p>See {@code keycloak.spi.mcp.md} §6.3.
 */
public final class HandoffTokenSigner
{
    /** Algorithm name expected by {@link SecretKeySpec} for HS256 / HMAC-SHA-256. */
    private static final String HMAC_SHA256 = "HmacSHA256";

    /** JWS alg header value per RFC 7518 §3.1; stable wire format. */
    private static final String JWS_ALG_HS256 = "HS256";

    private final McpSpiConfig config;
    private final ConcurrentMap<String, SignatureSignerContext> signerByRealm;

    public HandoffTokenSigner(McpSpiConfig config)
    {
        this.config = config;
        this.signerByRealm = new ConcurrentHashMap<>();
    }

    /**
     * Signs {@code payload} with the realm's current HMAC key. The payload is
     * serialised to JSON by Keycloak's bundled Jackson configuration.
     *
     * @param payload any object Jackson can serialise (e.g., a
     *     {@link PickerRequestToken}).
     * @param realmName lowercase, hyphenated realm name (e.g., {@code knobby-prod}).
     * @return compact-serialised JWS (three base64url segments joined by '.').
     * @throws io.knobby.keycloak.mcp.config.McpSpiConfigException if the
     *     realm's HMAC key env var is missing or malformed.
     */
    public String sign(Object payload, String realmName)
    {
        SignatureSignerContext signer = signerByRealm.computeIfAbsent(
                realmName, this::buildSigner);
        return new JWSBuilder()
                .type("JWT")
                .jsonContent(payload)
                .sign(signer);
    }

    private SignatureSignerContext buildSigner(String realmName)
    {
        String base64Key = config.handoffHmacKey(realmName);
        byte[] bytes = Base64.getDecoder().decode(base64Key);
        SecretKey secretKey = new SecretKeySpec(bytes, HMAC_SHA256);
        KeyWrapper wrapper = new KeyWrapper();
        wrapper.setSecretKey(secretKey);
        wrapper.setAlgorithm(JWS_ALG_HS256);
        return new MacSignatureSignerContext(wrapper);
    }
}
