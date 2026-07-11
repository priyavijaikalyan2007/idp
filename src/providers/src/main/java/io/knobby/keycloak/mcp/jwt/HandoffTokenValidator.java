/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: bb7424fb-692d-4b81-9ca3-b248d5c32ee8
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: HandoffTokenValidator
 * 📜 PURPOSE: Verifies a picker-result JWT against the active realm's HMAC
 *             key (accepting the previous key during rotation overlap),
 *             checks iss/aud/exp/iat claims, consumes the jti via a ReplayGuard,
 *             and returns the parsed PickerResultToken.
 * 🔗 RELATES: [[HandoffTokenSigner]], [[McpSpiConfig]], [[ReplayGuard]],
 *             [[HandoffValidationException]], [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [McpPickerCallbackResourceProvider] -> [this.validatePickerResult]
 *         -> [HMACProvider.verify | ReplayGuard.firstUse]
 * 🛡️ SECURITY: Constant-time signature comparison via HMACProvider. Cross-realm
 *              replay rejected at signature step (per-realm keys). The ReplayGuard
 *              (production: Keycloak's distributed SingleUseObjectProvider)
 *              prevents reuse within the validity window, cluster-wide (RT-010).
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.jwt;

import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

import org.keycloak.jose.jws.JWSInput;
import org.keycloak.jose.jws.JWSInputException;
import org.keycloak.jose.jws.crypto.HMACProvider;

import io.knobby.keycloak.mcp.config.McpSpiConfig;
import io.knobby.keycloak.mcp.jwt.HandoffValidationException.Code;
import io.knobby.keycloak.mcp.util.ReplayGuard;

/**
 * Validates picker-result tokens. One instance per JVM; thread-safe.
 *
 * <p>Caches are populated lazily and never invalidated for the JVM's lifetime
 * — removing the previous-key env var coincides with a container redeploy
 * (Plan §3.5). Replay defense is delegated to the {@link ReplayGuard} passed per
 * call; UUID v4 jti collisions across realms are astronomically unlikely, and the
 * caller namespaces the single-use key.
 *
 * <p>Expected issuer / audience strings are constants per the design spec
 * (§6.2). Clock skew tolerance is {@value #CLOCK_SKEW_SECONDS} seconds for
 * future-dated {@code iat}.
 *
 * <p>See {@code keycloak.spi.mcp.md} §6.4.
 */
public final class HandoffTokenValidator
{
    static final String EXPECTED_ISSUER = "knobby-web-mcp-consent";
    static final String EXPECTED_AUDIENCE = "keycloak-mcp-spi";
    static final long CLOCK_SKEW_SECONDS = 60L;

    private final McpSpiConfig config;
    private final Clock clock;
    private final ConcurrentMap<String, byte[]> currentKeyByRealm;
    private final ConcurrentMap<String, Optional<byte[]>> previousKeyByRealm;

    /** Production constructor: uses the system UTC clock. */
    public HandoffTokenValidator(McpSpiConfig config)
    {
        this(config, Clock.systemUTC());
    }

    /** Test seam: inject a fixed clock for expiry / future-dated tests. */
    public HandoffTokenValidator(McpSpiConfig config, Clock clock)
    {
        this.config = config;
        this.clock = clock;
        this.currentKeyByRealm = new ConcurrentHashMap<>();
        this.previousKeyByRealm = new ConcurrentHashMap<>();
    }

    /**
     * Validates {@code jwt} against the realm's HMAC key(s) and standard JWT
     * claim rules, consumes the jti, and returns the parsed payload.
     *
     * @param jwt the compact-serialised JWS picker-result token.
     * @param realmName the realm hosting the callback (resolves which HMAC key
     *     is used for verification).
     * @return the parsed payload.
     * @throws HandoffValidationException with a specific {@link Code} on
     *     any validation failure.
     * @throws io.knobby.keycloak.mcp.config.McpSpiConfigException if the
     *     realm has no HMAC key configured.
     */
    public PickerResultToken validatePickerResult(
            String jwt, String realmName, ReplayGuard replayGuard)
    {
        byte[] currentKey = currentKeyByRealm.computeIfAbsent(realmName, this::loadCurrentKey);
        Optional<byte[]> previousKey =
                previousKeyByRealm.computeIfAbsent(realmName, this::loadPreviousKey);

        JWSInput input = parseOrThrow(jwt);
        verifySignatureOrThrow(input, currentKey, previousKey);

        PickerResultToken payload = readContentOrThrow(input);
        long now = Instant.now(clock).getEpochSecond();
        verifyClaims(payload, now);
        consumeJtiOrThrow(payload, now, replayGuard);

        return payload;
    }

    private JWSInput parseOrThrow(String jwt)
    {
        try
        {
            return new JWSInput(jwt);
        }
        catch (JWSInputException ex)
        {
            throw new HandoffValidationException(Code.MALFORMED, ex);
        }
    }

    private static void verifySignatureOrThrow(
            JWSInput input, byte[] currentKey, Optional<byte[]> previousKey)
    {
        if (HMACProvider.verify(input, currentKey))
        {
            return;
        }
        if (previousKey.isPresent() && HMACProvider.verify(input, previousKey.get()))
        {
            return;
        }
        throw new HandoffValidationException(Code.BAD_SIGNATURE);
    }

    private static PickerResultToken readContentOrThrow(JWSInput input)
    {
        try
        {
            return input.readJsonContent(PickerResultToken.class);
        }
        catch (JWSInputException ex)
        {
            throw new HandoffValidationException(Code.MALFORMED, ex);
        }
    }

    private void verifyClaims(PickerResultToken payload, long now)
    {
        if (!EXPECTED_ISSUER.equals(payload.getIss()))
        {
            throw new HandoffValidationException(Code.BAD_ISSUER);
        }
        if (!EXPECTED_AUDIENCE.equals(payload.getAud()))
        {
            throw new HandoffValidationException(Code.BAD_AUDIENCE);
        }
        if (payload.getExp() < now)
        {
            throw new HandoffValidationException(Code.EXPIRED);
        }
        if (payload.getIat() > now + CLOCK_SKEW_SECONDS)
        {
            throw new HandoffValidationException(Code.FUTURE_DATED);
        }
    }

    private void consumeJtiOrThrow(PickerResultToken payload, long now, ReplayGuard replayGuard)
    {
        // Keep the single-use record alive at least as long as the token is valid,
        // so a replay within its remaining lifetime is caught (min 1s).
        long lifespanSeconds = Math.max(1L, payload.getExp() - now);
        if (!replayGuard.firstUse(payload.getJti(), lifespanSeconds))
        {
            throw new HandoffValidationException(Code.REPLAY);
        }
    }

    private byte[] loadCurrentKey(String realmName)
    {
        return Base64.getDecoder().decode(config.handoffHmacKey(realmName));
    }

    private Optional<byte[]> loadPreviousKey(String realmName)
    {
        String prev = config.handoffHmacKeyPrevious(realmName);
        return prev == null
                ? Optional.empty()
                : Optional.of(Base64.getDecoder().decode(prev));
    }
}
