package com.fentanest.mysafetyreport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger
import java.util.regex.Pattern

/**
 * NotificationService — 알림 리스너
 *
 * 안전신문고/카카오톡 알림에서 신고번호를 추출해:
 *   - 서버 모드: /crawl/enqueue 로 POST
 *   - standalone 모드: "standalone_sync_pending" 플래그를 SharedPreferences 에 설정.
 *                     Flutter 가 앱 실행/foreground 복귀 시 이 플래그를 확인해 SyncEngine 트리거.
 *
 * 크롤링 결과 알림은 WsService(WebSocket)가 담당하므로 여기서는 생성하지 않음.
 */
class NotificationService : NotificationListenerService() {
    private val TAG = "SafetyReportNS"

    // 신고번호 패턴 (SPP-YYMM-NNNNNNN 형식, 예: SPP-2603-1434237)
    private val reportNoPattern = Pattern.compile("SPP-\\d{4}-\\d{6,8}")
    private val progressNotifId = AtomicInteger(3000)

    companion object {
        const val NOTIF_CHANNEL_ENQUEUE = "enqueue_progress"
        const val NOTIF_CHANNEL_DETECTED = "standalone_detected"
    }

    override fun onCreate() {
        super.onCreate()
        createEnqueueChannel()
        createDetectedChannel()
    }

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
        val appMode = prefs.getString("flutter.appMode", "server") ?: "server"

        if (appMode == "standalone") {
            handleStandaloneDetection(prefs, reportNumber)
            return
        }

        // 서버 모드 — 기존 로직
        val baseUrl = prefs.getString("flutter.baseUrl", "")?.trimEnd('/') ?: ""
        val apiKey = prefs.getString("flutter.apiKey", "") ?: ""

        if (baseUrl.isEmpty()) {
            Log.w(TAG, "baseUrl 미설정, 서버 전송 건너뜀")
            return
        }

        // WsService에서 crawl_started/crawl_finished 푸시 알림을 억제하도록 카운터 증가
        val currentCount = prefs.getInt("flutter.auto_enqueue_count", 0)
        prefs.edit()
            .putInt("flutter.auto_enqueue_count", currentCount + 1)
            .putLong("flutter.auto_enqueue_last_at", System.currentTimeMillis())
            .apply()

        val notifId = progressNotifId.getAndIncrement()
        showProgressNotif(notifId, reportNumber)

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
            } finally {
                cancelProgressNotif(notifId)
            }
        }.start()
    }

    /** standalone 모드: sync 트리거 플래그 설정 + 감지 알림 표시 */
    private fun handleStandaloneDetection(prefs: android.content.SharedPreferences, reportNumber: String) {
        // Flutter 가 감지하는 플래그. 증분 sync 의 트리거 역할.
        prefs.edit()
            .putBoolean("flutter.standalone_sync_pending", true)
            .putLong("flutter.standalone_last_detected_at", System.currentTimeMillis())
            .apply()

        Log.i(TAG, "standalone: sync 플래그 설정, 신고번호=$reportNumber")

        val notifId = progressNotifId.getAndIncrement()
        showDetectedNotif(notifId, reportNumber)
    }

    private fun showDetectedNotif(id: Int, reportNumber: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 앱 실행 intent — 사용자가 탭하면 Flutter 측 drainIfPending 트리거
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = if (intent != null) {
            android.app.PendingIntent.getActivity(
                this, id, intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val builder = Notification.Builder(this, NOTIF_CHANNEL_DETECTED)
            .setContentTitle("📬 신규 신고 감지")
            .setContentText("$reportNumber — 탭하면 동기화됩니다")
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setAutoCancel(true)
        if (pending != null) builder.setContentIntent(pending)
        nm.notify(id, builder.build())
    }

    private fun createDetectedChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIF_CHANNEL_DETECTED,
            "신규 신고 감지 (standalone)",
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = "standalone 모드에서 외부 알림으로부터 신규 신고번호 감지 시 표시"
            setShowBadge(true)
        }
        nm.createNotificationChannel(channel)
    }

    private fun showProgressNotif(id: Int, reportNumber: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notif = Notification.Builder(this, NOTIF_CHANNEL_ENQUEUE)
            .setContentTitle("📡 크롤링 지시 중...")
            .setContentText(reportNumber)
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setOngoing(true)
            .build()
        nm.notify(id, notif)
    }

    private fun cancelProgressNotif(id: Int) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(id)
    }

    private fun createEnqueueChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ENQUEUE,
            "크롤링 지시 진행",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "외부 앱 알림에서 크롤링 지시 전송 중 표시"
            setShowBadge(false)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {}
}
