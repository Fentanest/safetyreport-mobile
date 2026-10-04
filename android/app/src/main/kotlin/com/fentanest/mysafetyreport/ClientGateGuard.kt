package com.fentanest.mysafetyreport

import android.content.SharedPreferences
import org.json.JSONObject

/** Flutter의 최신 카카오 인증·동의 게이트 결과가 열려 있을 때만 Client 서버 작업을 시작한다. */
object ClientGateGuard {
    fun isOpen(prefs: SharedPreferences): Boolean = try {
        JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "")
            .let { cache ->
                val age = System.currentTimeMillis() - cache.optLong("verified_at", -1L)
                cache.optString("state") == "ok" && age >= 0 && age <= 600_000
            }
    } catch (_: Exception) {
        false
    }

    fun configStamp(prefs: SharedPreferences): String {
        val raw = listOf("flutter.appMode", "flutter.baseUrl", "flutter.apiKey", "flutter.standaloneUsername", "flutter.native_config_generation")
            .joinToString("\u0000") { prefs.all[it]?.toString() ?: "" } + "\u0000" + ownerScope(prefs)
        return java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    fun ownerScope(prefs: SharedPreferences): String = try {
        JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "").optString("owner", "")
    } catch (_: Exception) { "" }
}
