package com.fentanest.mysafetyreport

import android.content.SharedPreferences
import org.json.JSONObject

/** Flutter의 최신 카카오 인증·동의 게이트 결과가 열려 있을 때만 Client 서버 작업을 시작한다. */
object ClientGateGuard {
    fun isOpen(prefs: SharedPreferences): Boolean = try {
        JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "")
            .let { cache ->
                val age = System.currentTimeMillis() - cache.optLong("verified_at", -1L)
                cache.optString("state") == "ok" && age >= 0 && age <= VALID_MS
            }
    } catch (_: Exception) {
        false
    }

    /** 인증 확인 결과가 유효한 시간(10분). 늘리지 않는다 — 대신 만료 전에 갱신한다([needsRenewal]). */
    const val VALID_MS = 600_000L

    /** 이 나이를 넘으면 연결을 유지한 채 화면 없이 미리 다시 확인한다(만료 3분 전). */
    const val RENEW_AFTER_MS = 420_000L

    /** 열려 있지만 곧 만료된다 — 연결 중인 WsService 가 끊기기 전에 갱신을 요청한다. */
    fun needsRenewal(prefs: SharedPreferences): Boolean = try {
        JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "").let { cache ->
            val age = System.currentTimeMillis() - cache.optLong("verified_at", -1L)
            cache.optString("state") == "ok" && cache.optString("owner").isNotBlank() && age >= RENEW_AFTER_MS
        }
    } catch (_: Exception) { false }

    fun canRenew(prefs: SharedPreferences): Boolean = try {
        val cache = JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "")
        cache.optString("state") == "ok" && cache.optString("owner").isNotBlank()
    } catch (_: Exception) { false }

    fun configStamp(prefs: SharedPreferences): String {
        val raw = listOf("flutter.appMode", "flutter.baseUrl", "flutter.apiKey", "flutter.standaloneUsername", "flutter.native_config_generation")
            .joinToString("\u0000") { prefs.all[it]?.toString() ?: "" } + "\u0000" + ownerScope(prefs)
        return java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    fun ownerScope(prefs: SharedPreferences): String = try {
        JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "").optString("owner", "")
    } catch (_: Exception) { "" }
}
