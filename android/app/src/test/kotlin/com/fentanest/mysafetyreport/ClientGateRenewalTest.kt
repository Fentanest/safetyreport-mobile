package com.fentanest.mysafetyreport

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ClientGateRenewalTest {
    private fun prefs(state: String, age: Long, owner: String = "fixture-owner"): SharedPreferences {
        val raw = JSONObject().put("state", state).put("verified_at", System.currentTimeMillis() - age).put("owner", owner).toString()
        return Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, _ ->
            if (method.name == "getString") raw else error("unexpected call")
        } as SharedPreferences
    }
    @Test fun expiredGateRequiresRefreshButDoesNotMeanRevocation() {
        val p = prefs("ok", 601_000)
        assertFalse(ClientGateGuard.isOpen(p))
        assertTrue(ClientGateGuard.canRenew(p))
    }
    @Test fun explicitDenialAndMissingOwnerCannotKeepWebsocketAlive() {
        assertFalse(ClientGateGuard.canRenew(prefs("consent_required", 0)))
        assertFalse(ClientGateGuard.canRenew(prefs("ok", 601_000, "")))
    }
    @Test fun freshlyVerifiedGateCanSend() {
        assertTrue(ClientGateGuard.isOpen(prefs("ok", 100)))
    }
    // 2026-10-17: 연결 중에는 만료(10분) 3분 전부터 미리 갱신을 요청한다. 유효 시간 자체는 늘리지 않는다.
    @Test fun renewalStartsBeforeExpiryWithoutExtendingValidity() {
        assertFalse(ClientGateGuard.needsRenewal(prefs("ok", 100)))
        val aging = prefs("ok", ClientGateGuard.RENEW_AFTER_MS + 1_000)
        assertTrue(ClientGateGuard.needsRenewal(aging))
        assertTrue(ClientGateGuard.isOpen(aging))
        assertFalse(ClientGateGuard.isOpen(prefs("ok", ClientGateGuard.VALID_MS + 1_000)))
        assertEquals(600_000L, ClientGateGuard.VALID_MS)
    }
    @Test fun deniedOrOwnerlessGateIsNeverRenewedInBackground() {
        assertFalse(ClientGateGuard.needsRenewal(prefs("consent_required", 500_000)))
        assertFalse(ClientGateGuard.needsRenewal(prefs("ok", 500_000, "")))
    }
}
