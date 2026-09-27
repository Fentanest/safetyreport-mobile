package com.fentanest.mysafetyreport

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 저장된 Client 설정도 서버 작업 전에 v3 이상인지 확인한다. 실패하면 연결하지 않는다. */
object ServerVersionCompatibility {
    fun supports(version: String): Boolean {
        val match = Regex("^v?([0-9]+)(?:\\.[0-9]+){2,3}(?:[-+][0-9A-Za-z.-]+)?$")
            .matchEntire(version.trim()) ?: return false
        return (match.groupValues[1].toIntOrNull() ?: 0) >= 3
    }

    fun check(baseUrl: String, apiKey: String): Boolean {
        if (baseUrl.isBlank() || apiKey.isBlank()) return false
        var connection: HttpURLConnection? = null
        return try {
            val active = URL(ServerContract.apiUrl(baseUrl, ServerContract.SERVER_VERSION_PATH))
                .openConnection() as HttpURLConnection
            connection = active
            active.requestMethod = "GET"
            active.setRequestProperty(ServerContract.API_KEY_HEADER, apiKey)
            active.connectTimeout = 10_000
            active.readTimeout = 10_000
            if (active.responseCode != 200) return false
            val version = JSONObject(active.inputStream.bufferedReader().use { it.readText() })
                .optString("version")
            supports(version)
        } catch (_: Exception) {
            false
        } finally {
            connection?.disconnect()
        }
    }
}
