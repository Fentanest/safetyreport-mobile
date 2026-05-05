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
 *   - standalone 모드: 큐 (flutter.standalone_pending_reports) 에 신고번호 append.
 *                     Flutter 가 앱 실행/foreground 복귀 시 큐 비어있지 않으면 drain 트리거.
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
        // v2: 이전 채널(DEFAULT)이 이미 생성된 기기에서 HIGH 로 변경이 안 먹혀 새 ID 사용
        const val NOTIF_CHANNEL_DETECTED = "standalone_detected_v2"
        const val PREFS_PENDING_QUEUE = "flutter.standalone_pending_reports"
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
                val conn = java.net.URL(
                    ServerContract.apiUrl(baseUrl, ServerContract.CRAWL_ENQUEUE_PATH)
                )
                    .openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty(ServerContract.API_KEY_HEADER, apiKey)
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

    /** standalone 모드: 신고번호 큐에 추가 + 감지 알림 표시 */
    private fun handleStandaloneDetection(prefs: android.content.SharedPreferences, reportNumber: String) {
        appendPendingReport(prefs, reportNumber)
        // 마지막 감지 시각만 기록 (디버그/통계 용). 큐 비어있지 않음 신호는 큐 자체가 진실.
        prefs.edit()
            .putLong("flutter.standalone_last_detected_at", System.currentTimeMillis())
            .apply()

        Log.i(TAG, "standalone: 신고번호 큐 추가, 신고번호=$reportNumber")

        val notifId = progressNotifId.getAndIncrement()
        showDetectedNotif(notifId, reportNumber)
    }

    /**
     * Pending 큐 append — CSV 형식 (LIST_IDENTIFIER prefix 없음).
     *
     * 주의: Flutter 의 `LegacySharedPreferencesPlugin` 은 LIST_PREFIX
     * (`VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu`) 가 붙은 값을 Java
     * `ObjectInputStream` 으로 디코딩하려 함. 따라서 JSON 배열을 그 prefix 와
     * 함께 저장하면 `StreamCorruptedException` 이 발생해서 `getAll()` 자체가
     * 실패 → 모든 SharedPreferences 가 안 읽힘 (로그인 풀림 등).
     *
     * 일반 String (콤마 구분 CSV) 으로 저장하면 Flutter 는 이를 단순 String 으로
     * 인식해 디코딩 시도하지 않음. 신고번호는 SPP-NNNN-NNNNNNN 형식이라 콤마 없음.
     */
    private fun appendPendingReport(prefs: android.content.SharedPreferences, reportNumber: String) {
        val raw = prefs.getString(PREFS_PENDING_QUEUE, "") ?: ""
        val current = raw.split(",").filter { it.isNotEmpty() }.toMutableList()
        if (!current.contains(reportNumber)) current.add(reportNumber)
        prefs.edit().putString(PREFS_PENDING_QUEUE, current.joinToString(",")).apply()
    }

    private fun showDetectedNotif(id: Int, reportNumber: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // 앱 실행 intent — 동기화 탭(인덱스 6)으로 이동 + Flutter drainIfPending 트리거
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                    android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("nav_tab", 6)
            putExtra("nav_event_type", "standalone_sync")
        }
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
            // heads-up 팝업 유도 — 알림창에 일시적으로 떠오름
            .setPriority(Notification.PRIORITY_HIGH)
            .setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
            .setCategory(Notification.CATEGORY_MESSAGE)
        if (pending != null) builder.setContentIntent(pending)
        nm.notify(id, builder.build())
    }

    private fun createDetectedChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIF_CHANNEL_DETECTED,
            "신규 신고 감지 (standalone)",
            // HIGH: heads-up(팝업) 알림 표시 + 소리 + 진동
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "standalone 모드에서 외부 알림으로부터 신규 신고번호 감지 시 팝업 표시"
            setShowBadge(true)
            enableLights(true)
            enableVibration(true)
        }
        nm.createNotificationChannel(channel)
    }

    private fun showProgressNotif(id: Int, reportNumber: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notif = Notification.Builder(this, NOTIF_CHANNEL_ENQUEUE)
            .setContentTitle("📡 개별 크롤링 지시 중...")
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
            "개별 크롤링 지시 진행",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "외부 앱 알림에서 감지한 개별 신고 크롤링 지시 전송 중 표시"
            setShowBadge(false)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {}
}
