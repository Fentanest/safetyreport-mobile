package com.fentanest.mysafetyreport

import android.content.SharedPreferences
import org.json.JSONObject

/** Flutter의 최신 카카오 인증·동의 게이트 결과가 열려 있을 때만 Client 서버 작업을 시작한다. */
object ClientGateGuard {
    fun isOpen(prefs: SharedPreferences): Boolean = try {
        JSONObject(prefs.getString("flutter.community_gate_cache_v1", "") ?: "")
            .optString("state") == "ok"
    } catch (_: Exception) {
        false
    }
}
