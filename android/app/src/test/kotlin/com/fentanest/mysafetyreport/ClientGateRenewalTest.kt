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
}
