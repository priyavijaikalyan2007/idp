/*
 * SPDX-FileCopyrightText: 2026 Outcrop Inc.
 * SPDX-License-Identifier: MIT
 * SPDX-FileContributor: Priyavijai Kalyan <priyavijai.kalyan@gmail.com>
 * SPDX-FileUID: c138788f-454a-4952-85db-d05980ef17a0
 * Repository: yourapp/idp
 * Created: 2026-06-08
 */
package io.yourapp.keycloak.mcp.jwt;

import org.junit.jupiter.api.Test;

import io.yourapp.keycloak.mcp.jwt.HandoffValidationException.Code;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;

class HandoffValidationExceptionTest
{
    @Test
    void getCode_returnsConstructorCode()
    {
        HandoffValidationException ex = new HandoffValidationException(Code.BAD_SIGNATURE);

        assertEquals(Code.BAD_SIGNATURE, ex.getCode());
        assertEquals("BAD_SIGNATURE", ex.getMessage());
    }

    @Test
    void causedConstructor_preservesCause()
    {
        Throwable cause = new RuntimeException("underlying");
        HandoffValidationException ex = new HandoffValidationException(Code.MALFORMED, cause);

        assertEquals(Code.MALFORMED, ex.getCode());
        assertSame(cause, ex.getCause());
    }
}
