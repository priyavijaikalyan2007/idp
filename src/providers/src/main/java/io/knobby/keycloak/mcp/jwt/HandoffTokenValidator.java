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
 *             checks iss/aud/exp/iat claims, consumes the jti via ReplayCache,
 *             and returns the parsed PickerResultToken.
 * 🔗 RELATES: [[HandoffTokenSigner]], [[McpSpiConfig]], [[ReplayCache]],
 *             [[HandoffValidationException]], [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [McpPickerCallbackResourceProvider] -> [this.validatePickerResult]
 *         -> [HMACProvider.verify | ReplayCache.tryConsume]
 * 🛡️ SECURITY: Constant-time signature comparison via HMACProvider. Cross-realm
 *              replay rejected at signature step (per-realm keys). Replay cache
 *              prevents reuse within validity window.
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
import io.knobby.keycloak.mcp.util.ReplayCache;

/**
 * Validates picker-result tokens. One instance per JVM; thread-safe.
 *
 * <p>Caches are populated lazily and never invalidated for the JVM's lifetime
 * — removing the previous-key env var coincides with a container redeploy
 * (Plan §3.5). The replay cache is a global ReplayCache across all realms;
 * UUID v4 jti collisions across realms are astronomically unlikely.
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
    private final ReplayCache replayCache;
    private final Clock clock;
    private final ConcurrentMap<String, byte[]> currentKeyByRealm;
    private final ConcurrentMap<String, Optional<byte[]>> previousKeyByRealm;

    /** Production constructor: uses the system UTC clock. */
    public HandoffTokenValidator(McpSpiConfig config, ReplayCache replayCache)
    {
        this(config, replayCache, Clock.systemUTC());
    }

    /** Test seam: inject a fixed clock for expiry / future-dated tests. */
    public HandoffTokenValidator(McpSpiConfig config, ReplayCache replayCache, Clock clock)
    {
        this.config = config;
        this.replayCache = replayCache;
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
    public PickerResultToken validatePickerResult(String jwt, String realmName)
    {
        byte[] currentKey = currentKeyByRealm.computeIfAbsent(realmName, this::loadCurrentKey);
        Optional<byte[]> previousKey =
                previousKeyByRealm.computeIfAbsent(realmName, this::loadPreviousKey);

        JWSInput input = parseOrThrow(jwt);
        verifySignatureOrThrow(input, currentKey, previousKey);

        PickerResultToken payload = readContentOrThrow(input);
        verifyClaims(payload);
        consumeJtiOrThrow(payload);

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

    private void verifyClaims(PickerResultToken payload)
    {
        if (!EXPECTED_ISSUER.equals(payload.getIss()))
        {
            throw new HandoffValidationException(Code.BAD_ISSUER);
        }
        if (!EXPECTED_AUDIENCE.equals(payload.getAud()))
        {
            throw new HandoffValidationException(Code.BAD_AUDIENCE);
        }
        long now = Instant.now(clock).getEpochSecond();
        if (payload.getExp() < now)
        {
            throw new HandoffValidationException(Code.EXPIRED);
        }
        if (payload.getIat() > now + CLOCK_SKEW_SECONDS)
        {
            throw new HandoffValidationException(Code.FUTURE_DATED);
        }
    }

    private void consumeJtiOrThrow(PickerResultToken payload)
    {
        if (!replayCache.tryConsume(payload.getJti(), payload.getExp()))
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
