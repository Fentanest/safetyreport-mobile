package com.fentanest.mysafetyreport

import android.net.Uri

object ServerContract {
    const val PROTOCOL_VERSION = 3
    var productVersion: String = ""
    fun headers(apiKey: String): Map<String, String> = mapOf(
        API_KEY_HEADER to apiKey,
        "X-SafetyReport-Client" to "mobile",
        "X-SafetyReport-Version" to productVersion,
        "X-SafetyReport-Protocol" to PROTOCOL_VERSION.toString(),
    )

    const val API_PREFIX = "/api/v1"
    const val API_KEY_HEADER = "X-API-Key"
    const val WS_EVENTS_PATH = "/ws/events"
    const val WS_API_KEY_QUERY = "api_key"
    const val TAXONOMY_VERSION = "5"

    const val EVENT_PING = "ping"
    const val EVENT_CONNECTED = "connected"
    const val EVENT_CRAWL_STARTED = "crawl_started"
    const val EVENT_CRAWL_FINISHED = "crawl_finished"
    const val EVENT_CRAWL_CHANGES = "crawl_changes"

    const val CRAWL_ENQUEUE_PATH = "$API_PREFIX/crawl/enqueue"
    // request_id 없는 옛 경로. 새 경로가 없는(404) 구서버로 notification_background.dart 가 확인되면
    // 이 경로로 대신 보낸다(2026-10 redroid 실측: 운영 PC 서버에 CRAWL_NOTIFICATION_PATH 가 없어 404).
    const val CRAWL_NOTIFICATION_PATH = "$API_PREFIX/crawl/notification"
    const val SERVER_VERSION_PATH = "$API_PREFIX/server/version"

    fun normalizeBaseUrl(baseUrl: String): String = baseUrl.trimEnd('/')

    fun wsEventsUrl(baseUrl: String, apiKey: String): String {
        val httpUri = Uri.parse(normalizeBaseUrl(baseUrl))
        val scheme = if (httpUri.scheme == "https") "wss" else "ws"
        return Uri.Builder()
            .scheme(scheme)
            .encodedAuthority(
                if (httpUri.port != -1) "${httpUri.host}:${httpUri.port}" else httpUri.host
            )
            .path(WS_EVENTS_PATH)
            .appendQueryParameter(WS_API_KEY_QUERY, apiKey)
            .appendQueryParameter("client_type", "mobile")
            .appendQueryParameter("client_version", productVersion)
            .appendQueryParameter("client_protocol", PROTOCOL_VERSION.toString())
            // 5분류 지원 신호(서버 services/ws_manager.py: query_params['taxonomy'] != '5' 면 브로드캐스트를 3분류로 접는다).
            .appendQueryParameter("taxonomy", TAXONOMY_VERSION)
            .build()
            .toString()
    }

    fun apiUrl(baseUrl: String, path: String): String {
        return normalizeBaseUrl(baseUrl) + path
    }
}
