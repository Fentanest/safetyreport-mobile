package com.fentanest.mysafetyreport

import android.net.Uri

object ServerContract {
    const val API_PREFIX = "/api/v1"
    const val API_KEY_HEADER = "X-API-Key"
    const val WS_EVENTS_PATH = "/ws/events"
    const val WS_API_KEY_QUERY = "api_key"

    const val EVENT_PING = "ping"
    const val EVENT_CONNECTED = "connected"
    const val EVENT_CRAWL_STARTED = "crawl_started"
    const val EVENT_CRAWL_FINISHED = "crawl_finished"
    const val EVENT_CRAWL_CHANGES = "crawl_changes"

    const val CRAWL_ENQUEUE_PATH = "$API_PREFIX/crawl/enqueue"

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
            .build()
            .toString()
    }

    fun apiUrl(baseUrl: String, path: String): String {
        return normalizeBaseUrl(baseUrl) + path
    }
}
