package com.fentanest.mysafetyreport

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.regex.Pattern

/**
 * NotificationService — 알림 리스너
 *
 * 안전신문고/카카오톡 알림에서 신고번호를 추출해 서버 /crawl/enqueue에 전송.
 * 크롤링 결과 알림은 WsService(WebSocket)가 담당하므로 여기서는 생성하지 않음.
 */
class NotificationService : NotificationListenerService() {
    private val TAG = "SafetyReportNS"

    // 신고번호 패턴 (SPP-YYMM-NNNNNNN 형식, 예: SPP-2603-1434237)
    private val reportNoPattern = Pattern.compile("SPP-\\d{4}-\\d{6,8}")

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val packageName = sbn.packageName
        val extras = sbn.notification.extras
        val title = extras.getString("android.title") ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        Log.d(TAG, "알림 수신: $packageName")
        Log.d(TAG, "제목: $title, 내용: $text")

        if (packageName == "kr.go.safepeople" || packageName == "com.kakao.talk") {
            extractAndEnqueue("$title $text")
        }
    }

    private fun extractAndEnqueue(text: String) {
        val matcher = reportNoPattern.matcher(text)
        while (matcher.find()) {
            val reportNumber = matcher.group()
            Log.i(TAG, "신고번호 추출: $reportNumber")
            sendEnqueue(reportNumber)
        }
    }

    private fun sendEnqueue(reportNumber: String) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val baseUrl = prefs.getString("flutter.baseUrl", "")?.trimEnd('/') ?: ""
        val apiKey = prefs.getString("flutter.apiKey", "") ?: ""

        if (baseUrl.isEmpty()) {
            Log.w(TAG, "baseUrl 미설정, 서버 전송 건너뜀")
            return
        }

        Thread {
            try {
                val conn = java.net.URL("$baseUrl/api/v1/crawl/enqueue")
                    .openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("X-API-Key", apiKey)
                conn.doOutput = true

                val body = "{\"report_number\": \"$reportNumber\"}"
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }

                Log.i(TAG, "큐 전송 응답: ${conn.responseCode}")
                conn.disconnect()
            } catch (e: Exception) {
                Log.e(TAG, "서버 전송 오류: ${e.message}")
            }
        }.start()
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {}
}
