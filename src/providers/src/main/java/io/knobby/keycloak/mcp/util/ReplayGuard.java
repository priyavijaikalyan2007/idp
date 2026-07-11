/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 6b1d4e2a-3f7c-4a91-9c2e-1b8d5f0a7e34
 * Repository: knobby/idp
 * Created: 2026-07-11
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: ReplayGuard
 * 📜 PURPOSE: One-shot consume-once check for a picker-result jti. Abstracts the
 *             backing store so production uses Keycloak's distributed
 *             SingleUseObjectProvider (RT-010) while tests use an in-memory map.
 * 🔗 RELATES: [[HandoffTokenValidator]], [[McpPickerCallbackResourceProvider]]
 * ⚡ FLOW: [HandoffTokenValidator.validatePickerResult] -> [this.firstUse]
 * 🛡️ SECURITY: The replay defense for the handoff. Production impl must be
 *              cluster-wide + restart-durable so the guarantee does not depend on
 *              running a single instance.
 * ----------------------------------------------------------------------------
 */
package io.knobby.keycloak.mcp.util;

/**
 * A distributed, single-use consume check for JWT {@code jti} values.
 *
 * <p>Production wires this to {@code session.singleUseObjects().putIfAbsent(...)}
 * (Infinispan-backed, TTL-aware, restart-durable), so the replay guarantee no
 * longer depends on {@code maxScale=1}. Tests supply an in-memory implementation.
 */
@FunctionalInterface
public interface ReplayGuard
{
    /**
     * Atomically records {@code jti} as consumed if it has not been seen.
     *
     * @param jti the JWT identifier to consume.
     * @param lifespanSeconds how long the record must survive — at least the
     *     token's remaining validity, so a replay within that window is caught.
     * @return {@code true} if this is the FIRST use (allow); {@code false} if the
     *     {@code jti} was already consumed (replay — reject).
     */
    boolean firstUse(String jti, long lifespanSeconds);
}
