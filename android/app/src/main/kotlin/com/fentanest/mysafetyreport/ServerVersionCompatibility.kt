package com.fentanest.mysafetyreport

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 저장된 Client 설정도 서버 작업 전에 v3 이상인지 확인한다. 실패하면 연결하지 않는다. */
object ServerVersionCompatibility {
    enum class Failure { NONE, INCOMPATIBLE, AUTH, NETWORK }
    @Volatile var failure = Failure.NONE
        private set
    @Volatile var failureMessage = ""
        private set
    @Volatile private var blockedAddress: String? = null
    @Volatile private var blockedKey: String? = null
    fun reset() { blockedAddress = null; blockedKey = null; failure = Failure.NONE; failureMessage = "" }
    fun upgradeMessage(code: String): String = when (code) {
        "SERVER_UPGRADE_REQUIRED" -> "PC 서버를 v3 이상으로 업데이트하세요."
        "CLIENT_UPGRADE_REQUIRED" -> "모바일 앱을 최신 버전으로 업데이트하세요."
        else -> "앱과 PC 서버의 통신 규약이 맞지 않습니다. protocol 3을 지원하는 앱과 서버로 업데이트하세요."
    }
    fun supportsPayload(body: JSONObject): Boolean {
        val protocols = body.optJSONArray("supported_client_protocols") ?: return false
        return supports(body.optString("version")) &&
            body.opt("protocol_version") == 3 &&
            (0 until protocols.length()).any { protocols.opt(it) == 3 }
    }
    fun supports(version: String): Boolean {
        val match = Regex("^v?([0-9]+)\\.[0-9]+\\.[0-9]+(?:\\.[0-9]+)?(?:-(?:dev|alpha|beta|rc)[.\\w-]*)?(?:\\+[\\w.-]+)?$")
            .matchEntire(version.trim()) ?: return false
        return (match.groupValues[1].toIntOrNull() ?: 0) >= 3
    }

    fun block(baseUrl: String, apiKey: String) {
        blockedAddress = baseUrl; blockedKey = apiKey; failure = Failure.INCOMPATIBLE
    }
    fun check(baseUrl: String, apiKey: String): Boolean {
        if (baseUrl.isBlank() || apiKey.isBlank()) return false
        if (blockedAddress == baseUrl && blockedKey == apiKey) return false
        var connection: HttpURLConnection? = null
        return try {
            val active = URL(ServerContract.apiUrl(baseUrl, ServerContract.SERVER_VERSION_PATH))
                .openConnection() as HttpURLConnection
            connection = active
            active.requestMethod = "GET"
            ServerContract.headers(apiKey).forEach { (name, value) -> active.setRequestProperty(name, value) }
            active.connectTimeout = 10_000
            active.readTimeout = 10_000
            failure = when (active.responseCode) {
                200 -> Failure.NONE
                401, 403 -> Failure.AUTH
                404, 409 -> Failure.INCOMPATIBLE
                else -> Failure.NETWORK
            }
            if (failure == Failure.NONE && !supportsPayload(
                JSONObject(active.inputStream.bufferedReader().use { it.readText() })
            )) failure = Failure.INCOMPATIBLE
            failureMessage = when (failure) {
                Failure.NONE -> ""
                Failure.AUTH -> "서버 API 키를 확인하세요."
                Failure.NETWORK -> "서버에 연결할 수 없습니다. 네트워크와 주소를 확인하세요."
                Failure.INCOMPATIBLE -> "PC 서버 v3 이상과 self-host protocol 3 지원을 확인하세요."
            }
            if (active.responseCode == 409) {
                val body = active.errorStream?.bufferedReader()?.use { it.readText() }
                failureMessage = upgradeMessage(body?.let { JSONObject(it).optString("code") } ?: "")
            }
            if (failure == Failure.INCOMPATIBLE || failure == Failure.AUTH) {
                blockedAddress = baseUrl; blockedKey = apiKey
            }
            failure == Failure.NONE
        } catch (_: Exception) {
            failure = Failure.NETWORK
            failureMessage = "서버에 연결할 수 없습니다. 네트워크와 주소를 확인하세요."
            false
        } finally {
            connection?.disconnect()
        }
    }
}
