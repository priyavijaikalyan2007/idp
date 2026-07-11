/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 63fe2c8b-57ec-4ed5-8446-e1c13bd5b155
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.jwt;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HashMap;
import java.util.Map;

import io.yourapp.keycloak.mcp.config.McpSpiConfig;
import io.yourapp.keycloak.mcp.jwt.HandoffValidationException.Code;
import io.yourapp.keycloak.mcp.util.ReplayGuard;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertSame;

class HandoffTokenValidatorTest
{
    private static final long T0 = Instant.parse("2026-06-08T12:00:00Z").getEpochSecond();
    private static final String KEY_A =
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    private static final String KEY_B =
            "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";

    // ------------------------------------------------------------------ valid

    @Test
    void validate_validToken_returnsParsedPayload()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        PickerResultToken original = validResultBuilder().build();
        String jwt = newSigner(env).sign(original, "yourapp-prod");

        PickerResultToken parsed = newValidator(env, T0)
                .validatePickerResult(jwt, "yourapp-prod", inMemoryGuard());

        assertEquals(original.getJti(), parsed.getJti());
        assertEquals(original.getChosenTenantId(), parsed.getChosenTenantId());
        assertEquals(original.getGrantedScopes(), parsed.getGrantedScopes());
    }

    // -------------------------------------------------------- signature failures

    @Test
    void validate_tamperedSignature_throwsBadSignature()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        String jwt = newSigner(env).sign(validResultBuilder().build(), "yourapp-prod");
        String tampered = tamperSignatureFirstChar(jwt);

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0).validatePickerResult(tampered, "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.BAD_SIGNATURE, ex.getCode());
    }

    @Test
    void validate_crossRealmReplay_throwsBadSignature()
    {
        // realm A signs with KEY_A, realm B holds KEY_B.
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_DEV", KEY_B);

        String prodJwt = newSigner(env).sign(validResultBuilder().build(), "yourapp-prod");

        // Replay against yourapp-dev's validator endpoint: must fail at signature.
        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0).validatePickerResult(prodJwt, "yourapp-dev", inMemoryGuard()));
        assertEquals(Code.BAD_SIGNATURE, ex.getCode());
    }

    @Test
    void validate_signedWithPreviousKey_accepted()
    {
        // Rotation overlap: current = KEY_B (new), previous = KEY_A (old).
        // A token signed with KEY_A must still validate.
        Map<String, String> envOld = new HashMap<>();
        envOld.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);
        String oldKeyJwt = newSigner(envOld).sign(validResultBuilder().build(), "yourapp-prod");

        Map<String, String> envRotated = new HashMap<>();
        envRotated.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_B);
        envRotated.put("YOURAPP_MCP_HANDOFF_HMAC_KEY_PREVIOUS__YOURAPP_PROD", KEY_A);

        PickerResultToken parsed = newValidator(envRotated, T0)
                .validatePickerResult(oldKeyJwt, "yourapp-prod", inMemoryGuard());
        assertEquals("res-jti-1", parsed.getJti());
    }

    @Test
    void validate_previousKeyAbsentAndCurrentMismatch_throwsBadSignature()
    {
        // Old (KEY_A) token presented but only KEY_B is configured, no previous.
        Map<String, String> envOld = new HashMap<>();
        envOld.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);
        String oldKeyJwt = newSigner(envOld).sign(validResultBuilder().build(), "yourapp-prod");

        Map<String, String> envCurrent = new HashMap<>();
        envCurrent.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_B);

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(envCurrent, T0).validatePickerResult(oldKeyJwt, "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.BAD_SIGNATURE, ex.getCode());
    }

    // ----------------------------------------------------------- claim failures

    @Test
    void validate_wrongIssuer_throwsBadIssuer()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        String jwt = newSigner(env).sign(
                validResultBuilder().iss("evil-iss").build(),
                "yourapp-prod");

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0).validatePickerResult(jwt, "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.BAD_ISSUER, ex.getCode());
    }

    @Test
    void validate_wrongAudience_throwsBadAudience()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        String jwt = newSigner(env).sign(
                validResultBuilder().aud("evil-aud").build(),
                "yourapp-prod");

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0).validatePickerResult(jwt, "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.BAD_AUDIENCE, ex.getCode());
    }

    @Test
    void validate_expired_throwsExpired()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        // Token expired at T0 - 1 second.
        String jwt = newSigner(env).sign(
                validResultBuilder().iat(T0 - 60).exp(T0 - 1).build(),
                "yourapp-prod");

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0).validatePickerResult(jwt, "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.EXPIRED, ex.getCode());
    }

    @Test
    void validate_futureDatedBeyondSkew_throwsFutureDated()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        // iat is 120 seconds in the future — exceeds the 60-sec skew tolerance.
        String jwt = newSigner(env).sign(
                validResultBuilder().iat(T0 + 120).exp(T0 + 180).build(),
                "yourapp-prod");

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0).validatePickerResult(jwt, "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.FUTURE_DATED, ex.getCode());
    }

    // ----------------------------------------------------------------- replay

    @Test
    void validate_replay_throwsReplay()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        String jwt = newSigner(env).sign(validResultBuilder().build(), "yourapp-prod");
        HandoffTokenValidator validator = newValidator(env, T0);
        ReplayGuard guard = inMemoryGuard(); // SAME guard across both calls

        validator.validatePickerResult(jwt, "yourapp-prod", guard); // first consume — OK

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> validator.validatePickerResult(jwt, "yourapp-prod", guard));
        assertEquals(Code.REPLAY, ex.getCode());
    }

    // -------------------------------------------------------------- malformed

    @Test
    void validate_malformedJwtString_throwsMalformed()
    {
        Map<String, String> env = new HashMap<>();
        env.put("YOURAPP_MCP_HANDOFF_HMAC_KEY__YOURAPP_PROD", KEY_A);

        HandoffValidationException ex = assertThrows(HandoffValidationException.class,
                () -> newValidator(env, T0)
                        .validatePickerResult("not-a-jwt", "yourapp-prod", inMemoryGuard()));
        assertEquals(Code.MALFORMED, ex.getCode());
    }

    // ------------------------------------------------------------- exception code

    @Test
    void handoffValidationException_codeAccessor()
    {
        HandoffValidationException ex = new HandoffValidationException(Code.REPLAY);
        assertSame(Code.REPLAY, ex.getCode());
    }

    // -------------------------------------------------------------- test helpers

    private static PickerResultToken.Builder validResultBuilder()
    {
        return PickerResultToken.builder()
                .iss(HandoffTokenValidator.EXPECTED_ISSUER)
                .aud(HandoffTokenValidator.EXPECTED_AUDIENCE)
                .pickerRequestJti("req-jti-1")
                .userSubEcho("user-sub-123")
                .chosenTenantId("tenant-uuid-1")
                .grantedScopes(java.util.List.of("yourapp:read"))
                .oauthState("oauth-state-xyz")
                .authSessionId("root-auth-1")
                .kcClientId("mcp-client-abc")
                .kcTabId("tab-1")
                .nonce("nonce-2")
                .jti("res-jti-1")
                .iat(T0 - 10)
                .exp(T0 + 60);
    }

    /**
     * Flips the first character of the signature segment. Tampering with the
     * first base64url char of the signature always changes a meaningful bit of
     * the decoded signature bytes; tampering with the LAST char can land on
     * the 2 unused bits when the signature length is exactly 256 bits (HS256).
     */
    private static String tamperSignatureFirstChar(String jwt)
    {
        String[] parts = jwt.split("\\.");
        char first = parts[2].charAt(0);
        char flipped = (first == 'A') ? 'B' : 'A';
        String tamperedSig = flipped + parts[2].substring(1);
        return parts[0] + "." + parts[1] + "." + tamperedSig;
    }

    private static HandoffTokenSigner newSigner(Map<String, String> env)
    {
        return new HandoffTokenSigner(new McpSpiConfig(env::get, () -> env));
    }

    private static HandoffTokenValidator newValidator(Map<String, String> env, long nowEpochSeconds)
    {
        McpSpiConfig config = new McpSpiConfig(env::get, () -> env);
        return new HandoffTokenValidator(config,
                Clock.fixed(Instant.ofEpochSecond(nowEpochSeconds), ZoneOffset.UTC));
    }

    /** A fresh in-memory replay guard: true on a jti's first use, false on repeat. */
    private static ReplayGuard inMemoryGuard()
    {
        java.util.Set<String> seen = new java.util.HashSet<>();
        return (jti, lifespanSeconds) -> seen.add(jti);
    }
}
