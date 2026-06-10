/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 297ec50b-38aa-4924-8900-355a07edd87a
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpSpiConfigException
 * 📜 PURPOSE: Thrown when realm-scoped SPI configuration (HMAC env var or
 *             Authenticator config property yourapp.web.host) is missing or
 *             malformed for the active realm.
 * 🔗 RELATES: [[McpSpiConfig]], [[McpTenantPickerAuthenticator]]
 * ⚡ FLOW: [McpSpiConfig | McpTenantPickerAuthenticator] -> [throw this] -> [Authenticator fails flow]
 * 🛡️ SECURITY: Message text names the parameter; never the secret value.
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.config;

/**
 * Discriminates SPI configuration failures by {@link Code}. Callers and
 * operators reading logs can act on the code without parsing message text.
 *
 * <p>See {@code keycloak.spi.mcp.md} §7.2 (resolution contract) and §8
 * (error-category table).
 */
public final class McpSpiConfigException extends RuntimeException
{
    /** Distinct failure modes surfaced to callers and logs. */
    public enum Code
    {
        /** Required env var is unset or blank. */
        MISSING_HMAC_KEY,
        /** Authenticator config property {@code yourapp.web.host} is unset for the realm. */
        MISSING_WEB_HOST,
        /** Env var is present but is not valid standard base64. */
        MALFORMED_BASE64,
        /** Env var decodes successfully but to a number of bytes other than 32. */
        WRONG_KEY_LENGTH
    }

    private final Code code;
    private final String parameterName;

    /**
     * @param code distinguishes the failure mode
     * @param parameterName the env-var name (HMAC codes) or config property name (web host)
     */
    public McpSpiConfigException(Code code, String parameterName)
    {
        super(buildMessage(code, parameterName, -1));
        this.code = code;
        this.parameterName = parameterName;
    }

    /**
     * @param code distinguishes the failure mode (intended for WRONG_KEY_LENGTH)
     * @param parameterName the env-var name
     * @param actualLength byte length of the decoded value (for diagnostic message text)
     */
    public McpSpiConfigException(Code code, String parameterName, int actualLength)
    {
        super(buildMessage(code, parameterName, actualLength));
        this.code = code;
        this.parameterName = parameterName;
    }

    public Code getCode()
    {
        return code;
    }

    public String getParameterName()
    {
        return parameterName;
    }

    private static String buildMessage(Code code, String parameterName, int actualLength)
    {
        return switch (code)
        {
            case MISSING_HMAC_KEY ->
                    "Required env var " + parameterName + " is not set";
            case MISSING_WEB_HOST ->
                    "Required Authenticator config property " + parameterName
                            + " is not set for this realm";
            case MALFORMED_BASE64 ->
                    "Env var " + parameterName + " is not valid standard base64";
            case WRONG_KEY_LENGTH ->
                    "Env var " + parameterName + " must decode to 32 bytes, got "
                            + actualLength;
        };
    }
}
