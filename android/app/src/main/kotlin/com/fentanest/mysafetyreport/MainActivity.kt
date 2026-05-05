package com.fentanest.mysafetyreport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.fentanest.mysafetyreport/permissions"
    private val notifIdGen = AtomicInteger(3000)
    private val NOTIF_CHANNEL_APP = "app_push_v2"
    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Flutter 엔진 시작 전에 손상된 SharedPreferences 정리.
        // (Flutter 가 SharedPreferences.getInstance() 호출 시 getAllPrefs() 가
        // 내부적으로 실행되는데, 손상된 List 항목이 있으면 StreamCorruptedException
        // 으로 모든 prefs 읽기 실패 → 로그인 풀림.)
        cleanupCorruptedPrefs()
        super.onCreate(savedInstanceState)
        // AndroidX 공식 edge-to-edge 진입점.
        // Android 15+ 의 기본 동작과 하위 버전 동작을 맞춰 주고,
        // 수동 WindowCompat.setDecorFitsSystemWindows(...) 경로를 제거한다.
        enableEdgeToEdge()
        createAppNotifChannel()
        // 앱이 종료 상태에서 알림 탭으로 실행된 경우 처리
        intent?.let { handleNavIntent(it) }
    }

    /**
     * v1 (LIST_IDENTIFIER prefix + JSON) 형식으로 저장된 standalone_pending_reports 를
     * CSV String 형식으로 마이그레이션.
     *
     * v1 형식은 Flutter 의 LegacyPlugin 이 List 로 인식해 Java deserialize 시도 →
     * JSON 데이터를 Java stream 으로 못 읽어 StreamCorruptedException 발생 →
     * getAll() 전체 실패. 우리가 쓴 JSON 은 Kotlin 에서는 파싱 가능하므로
     * 신고번호를 보존하면서 CSV 로 변환.
     */
    private fun cleanupCorruptedPrefs() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val key = "flutter.standalone_pending_reports"
        val flutterListPrefix = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
        val raw = prefs.getString(key, null) ?: return
        if (!raw.startsWith(flutterListPrefix)) return  // 이미 CSV 또는 빈 값

        val csv = try {
            val jsonStr = raw.substring(flutterListPrefix.length)
            val arr = org.json.JSONArray(jsonStr)
            val list = mutableListOf<String>()
            for (i in 0 until arr.length()) list.add(arr.getString(i))
            list.joinToString(",")
        } catch (_: Exception) {
            ""  // 파싱 실패 — 미처리 알림 손실 감수
        }
        prefs.edit().putString(key, csv).apply()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNavIntent(intent)
    }

    private fun handleNavIntent(intent: Intent) {
        val navTab = intent.getIntExtra("nav_tab", -1)
        val navSubTab = intent.getIntExtra("nav_subtab", -1)
        val eventType = intent.getStringExtra("nav_event_type") ?: ""
        if (navTab >= 0) {
            // MethodChannel이 준비되기 전(앱 콜드 스타트) 처리를 위해 약간 지연
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                methodChannel?.invokeMethod("navigateToTab", mapOf(
                    "tab" to navTab,
                    "sub_tab" to navSubTab,
                    "event_type" to eventType
                ))
            }, 500)
        }
    }

    private fun createAppNotifChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(NOTIF_CHANNEL_APP) == null) {
            val ch = NotificationChannel(
                NOTIF_CHANNEL_APP, "앱 알림", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "크롤링 완료 등 앱 이벤트 알림"
                enableVibration(true)
            }
            nm.createNotificationChannel(ch)
        }
    }

    private fun showLocalNotification(
        title: String,
        body: String,
        navTab: Int? = null,
        navSubTab: Int? = null,
        eventType: String? = null,
    ) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            if (navTab != null) putExtra("nav_tab", navTab)
            if (navSubTab != null) putExtra("nav_subtab", navSubTab)
            if (!eventType.isNullOrEmpty()) putExtra("nav_event_type", eventType)
        }
        val pi = PendingIntent.getActivity(
            this, notifIdGen.get(), openIntent ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif = Notification.Builder(this, NOTIF_CHANNEL_APP)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(notifIdGen.getAndIncrement(), notif)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {

                    // ── 알림 리스너 권한 ────────────────────────────────────
                    "isNotificationListenerEnabled" -> {
                        val flat = Settings.Secure.getString(
                            contentResolver,
                            "enabled_notification_listeners"
                        )
                        result.success(flat != null && flat.contains(packageName))
                    }
                    "openNotificationListenerSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }

                    // ── WsService 제어 ─────────────────────────────────────
                    "startWsService" -> {
                        try {
                            val intent = Intent(this, WsService::class.java).apply {
                                action = WsService.ACTION_START
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("WS_START_FAILED", e.message, null)
                        }
                    }
                    "stopWsService" -> {
                        try {
                            val intent = Intent(this, WsService::class.java).apply {
                                action = WsService.ACTION_STOP
                            }
                            startService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("WS_STOP_FAILED", e.message, null)
                        }
                    }
                    "isWsServiceRunning" -> {
                        val am = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                        @Suppress("DEPRECATION")
                        val running = am.getRunningServices(Int.MAX_VALUE).any {
                            it.service.className == WsService::class.java.name
                        }
                        result.success(running)
                    }

                    "showNotification" -> {
                        val title = call.argument<String>("title") ?: "알림"
                        val body  = call.argument<String>("body")  ?: ""
                        val navTab = call.argument<Int>("nav_tab")
                        val navSubTab = call.argument<Int>("nav_subtab")
                        val eventType = call.argument<String>("event_type")
                        showLocalNotification(title, body, navTab, navSubTab, eventType)
                        result.success(null)
                    }

                    // ── 동기화 Foreground Service 제어 ─────────────────────
                    // Flutter 가 ref counting 관리. 첫 start / 마지막 stop 만 호출됨.
                    "startSyncFgs" -> {
                        try {
                            val message = call.argument<String>("message") ?: "동기화 진행 중..."
                            val intent = Intent(this, SyncForegroundService::class.java).apply {
                                action = SyncForegroundService.ACTION_START
                                putExtra(SyncForegroundService.EXTRA_MESSAGE, message)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SYNC_FGS_START_FAILED", e.message, null)
                        }
                    }
                    "stopSyncFgs" -> {
                        try {
                            val intent = Intent(this, SyncForegroundService::class.java).apply {
                                action = SyncForegroundService.ACTION_STOP
                            }
                            startService(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SYNC_FGS_STOP_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        // 앱이 포그라운드로 돌아올 때 WsService 자동 시작 (설정이 완료된 경우)
        autoStartWsServiceIfConfigured()
    }

    private fun autoStartWsServiceIfConfigured() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val appMode = prefs.getString("flutter.appMode", "") ?: ""
        if (appMode != "server") {
            try {
                val intent = Intent(this, WsService::class.java).apply {
                    action = WsService.ACTION_STOP
                }
                startService(intent)
            } catch (_: Exception) {}
            return
        }
        
        val baseUrl = prefs.getString("flutter.baseUrl", "") ?: ""
        val apiKey  = prefs.getString("flutter.apiKey",  "") ?: ""
        if (baseUrl.isEmpty() || apiKey.isEmpty()) {
            try {
                val intent = Intent(this, WsService::class.java).apply {
                    action = WsService.ACTION_STOP
                }
                startService(intent)
            } catch (_: Exception) {}
            return
        }

        val intent = Intent(this, WsService::class.java).apply {
            action = WsService.ACTION_START
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (_: Exception) {}
    }
}
