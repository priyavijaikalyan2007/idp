/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 2da28ec6-1b5d-460c-bb50-9a9b717d9864
 * Repository: knobby/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: McpSpiConfig
 * 📜 PURPOSE: Resolves per-realm Keycloak MCP SPI configuration from environment
 *             variables. Two env-var slots per realm (current + optional previous
 *             during rotation overlap). Realm names map to env-var suffixes by
 *             uppercasing and replacing '-' with '_'.
 * 🔗 RELATES: [[McpSpiConfigException]], [[HandoffTokenSigner]], [[HandoffTokenValidator]]
 * ⚡ FLOW: [Signer | Validator | AuthenticatorFactory.init] -> [this] -> [System.getenv]
 * 🛡️ SECURITY: Returns the base64-encoded key as a String. Callers must not log
 *              the return value. Validation rejects malformed values fast.
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.config;

import java.util.Base64;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;

import io.knobby.keycloak.mcp.config.McpSpiConfigException.Code;

/**
 * Per-realm configuration façade. Lazy by design: env vars are read on first
 * request through each realm rather than enumerated at JVM startup. The
 * Authenticator factory's {@code init} method may call
 * {@link #realmsWithKeysConfigured()} to log a startup readiness summary.
 *
 * <p>See {@code keycloak.spi.mcp.md} §7 for the configuration model and
 * {@code keycloak-hmac-operations-guide.md} for the operator contract.
 */
public final class McpSpiConfig
{
    /** Prefix for current-slot env vars; suffix is the normalised realm name. */
    static final String ENV_KEY_PREFIX = "KNOBBY_MCP_HANDOFF_HMAC_KEY__";
    /** Prefix for previous-slot env vars (set only during a rotation overlap). */
    static final String ENV_KEY_PREVIOUS_PREFIX = "KNOBBY_MCP_HANDOFF_HMAC_KEY_PREVIOUS__";

    private static final int EXPECTED_KEY_BYTE_LENGTH = 32;

    private final Function<String, String> envSource;
    private final EnvEnumerator envEnumerator;

    /** Production constructor: reads from the JVM's environment. */
    public McpSpiConfig()
    {
        this(System::getenv, System::getenv);
    }

    /**
     * Test seam. {@code envSource} resolves a single env var name to its value
     * (returning {@code null} or empty if absent). {@code envEnumerator}
     * returns the full env map for prefix scans.
     *
     * <p>Public to allow tests in sibling packages (jwt, authenticator, resource)
     * to construct instances against a stub environment. Not intended for
     * production use — call the no-arg constructor.
     */
    public McpSpiConfig(Function<String, String> envSource, EnvEnumerator envEnumerator)
    {
        this.envSource = envSource;
        this.envEnumerator = envEnumerator;
    }

    /**
     * Returns the base64-encoded current HMAC key for the named realm.
     *
     * @param realmName Keycloak realm name (lowercase with hyphens).
     * @return validated base64 of a 32-byte key.
     * @throws McpSpiConfigException if the env var is missing, not valid
     *     standard base64, or does not decode to exactly 32 bytes.
     */
    public String handoffHmacKey(String realmName)
    {
        String envName = ENV_KEY_PREFIX + normalise(realmName);
        return validatedKey(envName);
    }

    /**
     * Returns the base64-encoded previous HMAC key for the named realm, or
     * {@code null} when none is configured (steady-state outside a rotation).
     *
     * @throws McpSpiConfigException if the previous-slot env var is present
     *     but malformed.
     */
    public String handoffHmacKeyPrevious(String realmName)
    {
        String envName = ENV_KEY_PREVIOUS_PREFIX + normalise(realmName);
        String value = envSource.apply(envName);
        if (isBlank(value))
        {
            return null;
        }
        return validatedKey(envName);
    }

    /**
     * Returns the set of realm names (lowercase, hyphenated) for which a
     * current-slot HMAC env var is present. Operator-visible at startup via
     * the Authenticator factory.
     */
    public Set<String> realmsWithKeysConfigured()
    {
        Map<String, String> env = envEnumerator.snapshot();
        Set<String> realms = new HashSet<>();
        for (Map.Entry<String, String> entry : env.entrySet())
        {
            String name = entry.getKey();
            if (!name.startsWith(ENV_KEY_PREFIX))
            {
                continue;
            }
            String suffix = name.substring(ENV_KEY_PREFIX.length());
            realms.add(denormalise(suffix));
        }
        return realms;
    }

    /** Maps a realm name to its env-var suffix (e.g., {@code knobby-prod -> KNOBBY_PROD}). */
    static String normalise(String realmName)
    {
        return realmName.toUpperCase(Locale.ROOT).replace('-', '_');
    }

    private static String denormalise(String envSuffix)
    {
        return envSuffix.toLowerCase(Locale.ROOT).replace('_', '-');
    }

    private String validatedKey(String envName)
    {
        String value = envSource.apply(envName);
        if (isBlank(value))
        {
            throw new McpSpiConfigException(Code.MISSING_HMAC_KEY, envName);
        }

        byte[] bytes;
        try
        {
            bytes = Base64.getDecoder().decode(value);
        }
        catch (IllegalArgumentException ex)
        {
            throw new McpSpiConfigException(Code.MALFORMED_BASE64, envName);
        }

        if (bytes.length != EXPECTED_KEY_BYTE_LENGTH)
        {
            throw new McpSpiConfigException(Code.WRONG_KEY_LENGTH, envName, bytes.length);
        }
        return value;
    }

    private static boolean isBlank(String value)
    {
        return value == null || value.isBlank();
    }

    /**
     * Test seam for enumerating env vars by prefix.
     *
     * <p>Public for the same reason as the test-seam constructor — tests in
     * sibling packages need to stub the environment.
     */
    public interface EnvEnumerator
    {
        Map<String, String> snapshot();
    }
}
