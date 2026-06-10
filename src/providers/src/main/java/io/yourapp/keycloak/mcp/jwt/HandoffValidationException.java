/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 3a138c3e-5f86-4cac-9efd-25ff8f9dae89
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: HandoffValidationException
 * 📜 PURPOSE: Thrown by HandoffTokenValidator when an incoming picker-result
 *             JWT fails signature, claim, replay, or user-mismatch checks.
 * 🔗 RELATES: [[HandoffTokenValidator]], [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [HandoffTokenValidator.validatePickerResult] -> [throw this] -> [Resource Provider returns HTTP 400]
 * 🛡️ SECURITY: Message contains only the code name; no PII, no key material.
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.jwt;

/**
 * Carries a {@link Code} identifying which validation step failed.
 *
 * <p>The resource provider maps these codes to HTTP 400 responses with an
 * {@code error=invalid_handoff} body whose {@code error_description} echoes
 * the code name. Per {@code keycloak.spi.mcp.md} §8, log lines include the
 * code and {@code jti} but never the raw token.
 */
public final class HandoffValidationException extends RuntimeException
{
    /** Failure modes returned by {@link HandoffTokenValidator}. */
    public enum Code
    {
        /** Token is not a well-formed JWS (wrong segment count, bad base64). */
        MALFORMED,
        /** Signature does not verify with either current or previous HMAC key. */
        BAD_SIGNATURE,
        /** {@code iss} claim does not equal {@code yourapp-web-mcp-consent}. */
        BAD_ISSUER,
        /** {@code aud} claim does not equal {@code keycloak-mcp-spi}. */
        BAD_AUDIENCE,
        /** {@code exp} claim is in the past. */
        EXPIRED,
        /** {@code iat} claim is more than the allowed skew in the future. */
        FUTURE_DATED,
        /** This token's {@code jti} has been observed already (replay attempt). */
        REPLAY,
        /** {@code user_sub_echo} does not match the auth session's user id. */
        USER_MISMATCH
    }

    private final Code code;

    public HandoffValidationException(Code code)
    {
        super(code.name());
        this.code = code;
    }

    public HandoffValidationException(Code code, Throwable cause)
    {
        super(code.name(), cause);
        this.code = code;
    }

    public Code getCode()
    {
        return code;
    }
}
