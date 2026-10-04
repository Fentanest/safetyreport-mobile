package com.fentanest.mysafetyreport

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 저장된 Client 설정도 서버 작업 전에 v3 이상인지 확인한다. 실패하면 연결하지 않는다. */
object ServerVersionCompatibility {
    enum class Failure { NONE, INCOMPATIBLE, AUTH, NETWORK }
    data class Probe(val failure: Failure, val message: String = "") {
        val accepted: Boolean get() = failure == Failure.NONE
    }
    private data class Blocked(val address: String, val key: String, val result: Probe)
    @Volatile private var blocked: Blocked? = null
    fun reset() { blocked = null }
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
        blocked = Blocked(baseUrl, apiKey, Probe(Failure.INCOMPATIBLE, upgradeMessage("")))
    }
    fun check(baseUrl: String, apiKey: String): Boolean = probe(baseUrl, apiKey).accepted
    fun probe(baseUrl: String, apiKey: String): Probe {
        if (baseUrl.isBlank() || apiKey.isBlank()) return Probe(Failure.NETWORK)
        blocked?.let { if (it.address == baseUrl && it.key == apiKey) return it.result }
        var connection: HttpURLConnection? = null
        val deadline = java.util.Timer(true)
        return try {
            val active = URL(ServerContract.apiUrl(baseUrl, ServerContract.SERVER_VERSION_PATH)).openConnection() as HttpURLConnection
            connection = active
            deadline.schedule(object : java.util.TimerTask() { override fun run() { active.disconnect() } }, 30_000L)
            active.requestMethod = "GET"
            ServerContract.headers(apiKey).forEach { (name, value) -> active.setRequestProperty(name, value) }
            active.connectTimeout = 10_000
            active.readTimeout = 10_000
            val status = active.responseCode
            var failure = when (status) {
                200 -> Failure.NONE
                401, 403 -> Failure.AUTH
                404, 409 -> Failure.INCOMPATIBLE
                else -> Failure.NETWORK
            }
            if (failure == Failure.NONE && !supportsPayload(JSONObject(readBounded(active.inputStream)))) failure = Failure.INCOMPATIBLE
            var message = when (failure) {
                Failure.NONE -> ""
                Failure.AUTH -> "서버 API 키를 확인하세요."
                Failure.NETWORK -> "서버에 연결할 수 없습니다. 네트워크와 주소를 확인하세요."
                Failure.INCOMPATIBLE -> "PC 서버 v3 이상과 self-host protocol 3 지원을 확인하세요."
            }
            if (status == 409) {
                val body = active.errorStream?.let { readBounded(it) }
                message = upgradeMessage(body?.let { JSONObject(it).optString("code") } ?: "")
            }
            val result = Probe(failure, message)
            if (failure == Failure.INCOMPATIBLE || failure == Failure.AUTH) blocked = Blocked(baseUrl, apiKey, result)
            result
        } catch (_: Exception) {
            Probe(Failure.NETWORK, "서버에 연결할 수 없습니다. 네트워크와 주소를 확인하세요.")
        } finally {
            deadline.cancel()
            connection?.disconnect()
        }
    }
    private fun readBounded(stream: java.io.InputStream): String = stream.use { input ->
        val body = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            if (body.size() + n > 1_048_576) throw java.io.IOException("version response too large")
            body.write(buffer, 0, n)
        }
        body.toString(Charsets.UTF_8.name())
    }
}
