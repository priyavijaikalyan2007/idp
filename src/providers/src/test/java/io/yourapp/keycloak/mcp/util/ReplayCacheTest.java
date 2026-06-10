/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: 08c073b9-ea48-41cb-a8b0-e11a23c57485
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.util;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ReplayCacheTest
{
    private static final long T0 = Instant.parse("2026-06-08T12:00:00Z").getEpochSecond();

    @Test
    void tryConsume_firstUse_returnsTrue()
    {
        ReplayCache cache = new ReplayCache(fixedClockAt(T0));

        assertTrue(cache.tryConsume("jti-1", T0 + 60));
    }

    @Test
    void tryConsume_secondUseSameJti_returnsFalse()
    {
        ReplayCache cache = new ReplayCache(fixedClockAt(T0));
        cache.tryConsume("jti-1", T0 + 60);

        assertFalse(cache.tryConsume("jti-1", T0 + 60));
    }

    @Test
    void tryConsume_distinctJtis_allReturnTrue()
    {
        ReplayCache cache = new ReplayCache(fixedClockAt(T0));

        assertTrue(cache.tryConsume("jti-1", T0 + 60));
        assertTrue(cache.tryConsume("jti-2", T0 + 60));
        assertTrue(cache.tryConsume("jti-3", T0 + 60));
    }

    @Test
    void tryConsume_expiredEntry_evictedLazilyAllowsReConsumption()
    {
        MutableClock clock = new MutableClock(T0);
        ReplayCache cache = new ReplayCache(clock);
        cache.tryConsume("jti-1", T0 + 60);

        // Advance past the entry's expiry; the next call should evict it and
        // accept the same jti as a fresh observation.
        clock.advanceTo(T0 + 120);
        assertTrue(cache.tryConsume("jti-1", T0 + 180));
    }

    @Test
    void tryConsume_exceedsMaxSize_oldestEvicted()
    {
        ReplayCache cache = new ReplayCache(fixedClockAt(T0));

        // Fill the cache exactly to MAX_SIZE.
        for (int i = 0; i < ReplayCache.MAX_SIZE; i++)
        {
            cache.tryConsume("jti-" + i, T0 + 3600);
        }

        // The oldest entry ("jti-0") is the LRU. Inserting one more entry must
        // evict it, so re-consuming "jti-0" should return true (fresh).
        cache.tryConsume("jti-overflow", T0 + 3600);
        assertTrue(cache.tryConsume("jti-0", T0 + 3600));

        // The most-recently-inserted entry should still be remembered.
        assertFalse(cache.tryConsume("jti-overflow", T0 + 3600));
    }

    private static Clock fixedClockAt(long epochSeconds)
    {
        return Clock.fixed(Instant.ofEpochSecond(epochSeconds), ZoneOffset.UTC);
    }

    /** Mutable clock for tests that need to advance time. */
    private static final class MutableClock extends Clock
    {
        private long epochSeconds;

        MutableClock(long epochSeconds)
        {
            this.epochSeconds = epochSeconds;
        }

        void advanceTo(long newEpochSeconds)
        {
            this.epochSeconds = newEpochSeconds;
        }

        @Override
        public java.time.ZoneId getZone()
        {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(java.time.ZoneId zone)
        {
            return this;
        }

        @Override
        public Instant instant()
        {
            return Instant.ofEpochSecond(epochSeconds);
        }
    }
}
