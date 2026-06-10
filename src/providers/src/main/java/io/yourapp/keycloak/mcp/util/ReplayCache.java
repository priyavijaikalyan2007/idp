/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 81ecd3cc-90f6-458a-b908-f2fb964e85e9
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */

/*
 * ----------------------------------------------------------------------------
 * ⚓ COMPONENT: ReplayCache
 * 📜 PURPOSE: Bounded LRU set of consumed JWT jti identifiers. Rejects replays
 *             of picker-result tokens within their validity window.
 * 🔗 RELATES: [[HandoffTokenValidator]]
 * ⚡ FLOW: [HandoffTokenValidator.validatePickerResult] -> [this] -> [in-memory LinkedHashMap]
 * 🛡️ SECURITY: Replay defence is per-JVM. Multi-instance Keycloak would need
 *              Infinispan backing; current deployment is single-instance.
 * ----------------------------------------------------------------------------
 */
package io.yourapp.keycloak.mcp.util;

import java.time.Clock;
import java.time.Instant;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Synchronised bounded LRU mapping {@code jti -> expiry epoch-seconds}. Lazy
 * eviction of expired entries on each call. Single cache across all realms —
 * UUID v4 {@code jti} collisions across realms are astronomically unlikely.
 *
 * <p>See {@code keycloak.spi.mcp.md} §6.5.
 */
public final class ReplayCache
{
    /** Hard cap on cached entries. Beyond this, LRU eviction kicks in. */
    public static final int MAX_SIZE = 10_000;

    private final Clock clock;
    private final LinkedHashMap<String, Long> cache;

    /** Production constructor: uses the system UTC clock. */
    public ReplayCache()
    {
        this(Clock.systemUTC());
    }

    /** Test seam: inject a fixed clock to test expiry and rotation windows. */
    public ReplayCache(Clock clock)
    {
        this.clock = clock;
        // accessOrder = true so removeEldestEntry evicts least-recently used
        // when capacity is exceeded.
        this.cache = new LinkedHashMap<>(16, 0.75f, true)
        {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, Long> eldest)
            {
                return size() > MAX_SIZE;
            }
        };
    }

    /**
     * Records consumption of a {@code jti}. Returns {@code true} on first
     * observation; {@code false} if this {@code jti} was previously consumed.
     *
     * @param jti the JWT identifier to test and record.
     * @param expiryEpochSeconds the token's {@code exp} claim, in epoch seconds;
     *     entries are evicted lazily once their expiry is in the past.
     */
    public synchronized boolean tryConsume(String jti, long expiryEpochSeconds)
    {
        long now = Instant.now(clock).getEpochSecond();
        evictExpired(now);

        if (cache.containsKey(jti))
        {
            return false;
        }

        cache.put(jti, expiryEpochSeconds);
        return true;
    }

    private void evictExpired(long now)
    {
        Iterator<Map.Entry<String, Long>> it = cache.entrySet().iterator();
        while (it.hasNext())
        {
            Map.Entry<String, Long> entry = it.next();
            if (entry.getValue() < now)
            {
                it.remove();
            }
        }
    }
}
