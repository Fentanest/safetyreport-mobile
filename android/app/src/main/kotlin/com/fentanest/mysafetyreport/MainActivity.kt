package com.fentanest.mysafetyreport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log
import android.provider.Settings
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.fentanest.mysafetyreport/permissions"
    private val notifIdGen = AtomicInteger(3000)
    private val NOTIF_CHANNEL_APP = "app_push_v2"
    private val PREFS_NAME = "FlutterSharedPreferences"
    private val PREF_APP_MODE = "flutter.appMode"
    private val PREF_BASE_URL = "flutter.baseUrl"
    private val PREF_API_KEY = "flutter.apiKey"
    private val PREF_STANDALONE_USERNAME = "flutter.standaloneUsername"
    private val PREF_STANDALONE_DEMO_MODE = "flutter.standaloneDemoMode"
    private val QUICK_ACTION_ID = "mode_primary_action"
    private val EVENT_QUICK_SYNC = "quick_sync"
    private val EVENT_QUICK_CRAWL = "quick_crawl"
    private var exportResult: MethodChannel.Result? = null
    private var exportSource: java.io.File? = null
    private val EXPORT_REQUEST = 9136
    private var methodChannel: MethodChannel? = null
    /**
     * 아직 Dart 가 받지 못한 알림 탭 이동 요청(SQ-B05). Dart 처리기가 없으면(notImplemented) 지우지 않고,
     * Dart 가 `dartReady` 를 보내면 다시 보낸다. Dart 는 메인 화면이 붙을 때까지 요청을 보관한다.
     */
    private var pendingNav: Map<String, Any>? = null
    private var pendingNavInFlight = false
    private var syncStoppedListener: ((String, String) -> Unit)? = null
    private var communityAuthChannel: MethodChannel? = null
    /** Dart 가 `takePendingLink` 를 한 번이라도 불렀으면(핸들러 등록 완료) 새 링크 때 신호를 보낸다. */
    private var communityDartReady = false

    companion object {
        private const val SECURE_STORAGE_CHANNEL = "com.fentanest.mysafetyreport/secure_storage"
        // flutter_secure_storage 의 자료 파일·키 접두사(v9·v10 같음)와 Jetpack EncryptedSharedPreferences keyset 항목 이름.
        private const val SECURE_STORAGE_PREFS = "FlutterSecureStorage"
        private const val SECURE_STORAGE_KEY_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_"
        private const val ESP_KEYSET_PREFIX = "__androidx_security_crypto_encrypted_prefs_"
        // v9 가 알고리즘 변경 때 같은 파일에 적을 수 있는 메타 키(자료 아님) — 남은 ESP 항목으로 세지 않는다.
        private val SECURE_STORAGE_META_KEYS = setOf("FlutterSecureSAlgorithmKey", "FlutterSecureSAlgorithmStorage")
        private const val COMMUNITY_AUTH_CHANNEL = "com.fentanest.mysafetyreport/community_auth"
        private const val COMMUNITY_AUTH_SCHEME = "com.fentanest.mysafetyreport"
        private const val COMMUNITY_AUTH_HOST = "auth"
        private const val COMMUNITY_AUTH_PATH = "/callback"

        // 프로세스 안 한 칸짜리 보관함. 액티비티가 다시 만들어져도 남고, Dart 가 꺼내면 비운다.
        // 링크 원문(인가 코드 포함)은 로그에 남기지 않는다.
        private val communityLinkLock = Any()
        private var pendingCommunityAuthLink: String? = null
    }

    override fun onDestroy() {
        if (SyncForegroundService.stoppedListener === syncStoppedListener) {
            if (shouldDestroyEngineWithHost()) {
                SyncForegroundService.activeOwner?.let { owner -> syncStoppedListener?.invoke(owner, "engine_destroyed") }
                stopService(Intent(this, SyncForegroundService::class.java))
            }
            SyncForegroundService.stoppedListener = null
        }
        syncStoppedListener = null
        methodChannel = null
        pendingNav = null
        super.onDestroy()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Flutter 엔진 시작 전에 손상된 SharedPreferences 정리.
        // (Flutter 가 SharedPreferences.getInstance() 호출 시 getAllPrefs() 가
        // 내부적으로 실행되는데, 손상된 List 항목이 있으면 StreamCorruptedException
        // 으로 모든 prefs 읽기 실패 → 로그인 풀림.)
        cleanupCorruptedPrefs()
        // 커뮤니티 로그인 복귀 링크는 Flutter 가 intent 를 읽기 전에 꺼내고 intent 에서 지운다.
        // savedInstanceState 가 있으면(프로세스 복원) 시스템이 옛 intent 를 다시 준 것이므로 받지 않는다.
        captureCommunityAuthLink(intent, isRestore = savedInstanceState != null)
        // Android 15+ 기본 edge-to-edge 와 이전 버전 호환을 위해
        // 시스템 바 인셋만 직접 열고, AndroidX edge-to-edge 백포트의
        // deprecated system bar color 호출 경로는 피한다.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
        configureSystemBarAppearance()
        createAppNotifChannel()
        updateAppShortcuts()
        // 앱이 종료 상태에서 알림 탭으로 실행된 경우 처리
        intent?.let { handleNavIntent(it) }
    }

    private fun configureSystemBarAppearance() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }

        val isLightTheme =
            (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) !=
                Configuration.UI_MODE_NIGHT_YES
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = isLightTheme
            isAppearanceLightNavigationBars = isLightTheme
        }
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

        try {
            val arr = org.json.JSONArray(raw.substring(flutterListPrefix.length))
            val list = mutableListOf<String>()
            for (i in 0 until arr.length()) {
                val value = arr.get(i)
                check(value is String && value.isNotEmpty() && !value.contains(','))
                list.add(value)
            }
            NativeProcessingRecovery.quarantine(this, raw)
            check(prefs.edit().putString(key, list.joinToString(",")).commit())
        } catch (_: Exception) {
            // getAll cannot decode this entry. Remove it only after a durable
            // private copy and an explicit recovery flag, never replace by empty.
            try {
                NativeProcessingRecovery.quarantine(this, raw)
                NativeProcessingRecovery.mark(this)
                check(prefs.edit().remove(key).commit())
            } catch (_: Exception) {
                Log.w("ProcessingRecovery", "legacy queue retained; quarantine not confirmed")
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        val isCommunityLink = captureCommunityAuthLink(intent, isRestore = false)
        super.onNewIntent(intent)
        setIntent(intent)
        if (isCommunityLink) {
            notifyCommunityAuthLink()
        }
        handleNavIntent(intent)
    }

    /**
     * `com.fentanest.mysafetyreport://auth/callback` (scheme/host/path 정확히 일치) 만 받는다.
     * 받은 링크는 보관함에 넣고 intent 의 data 를 지워 재생성·최근 앱 복원 때 다시 처리되지 않게 한다.
     * 다른 data 를 가진 intent 는 건드리지 않는다.
     */
    private fun captureCommunityAuthLink(intent: Intent?, isRestore: Boolean): Boolean {
        val data = intent?.data ?: return false
        if (intent.action != Intent.ACTION_VIEW) return false
        if (data.scheme != COMMUNITY_AUTH_SCHEME ||
            data.host != COMMUNITY_AUTH_HOST ||
            data.path != COMMUNITY_AUTH_PATH ||
            data.userInfo != null ||
            data.port != -1
        ) {
            return false
        }
        intent.data = null
        val fromHistory =
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (isRestore || fromHistory) return false
        synchronized(communityLinkLock) {
            pendingCommunityAuthLink = data.toString()
        }
        return true
    }

    private fun takeCommunityAuthLink(): String? = synchronized(communityLinkLock) {
        val link = pendingCommunityAuthLink
        pendingCommunityAuthLink = null
        link
    }

    /** Dart 핸들러가 준비됐으면 "새 링크 있음" 신호만 보낸다. 링크 원문은 takePendingLink 로만 전달. */
    private fun notifyCommunityAuthLink() {
        if (!communityDartReady) return
        communityAuthChannel?.invokeMethod("onCommunityAuthLink", null)
    }

    private fun handleNavIntent(intent: Intent) {
        intent.getStringExtra("db_export_uri")?.let { raw ->
            val uri = android.net.Uri.parse(raw)
            val downloads = intent.getBooleanExtra("db_export_downloads", true)
            val filename = intent.getStringExtra("db_export_filename")
            val location = intent.getStringExtra("db_export_location")
            intent.removeExtra("db_export_uri")
            intent.removeExtra("db_export_downloads")
            intent.removeExtra("db_export_filename")
            intent.removeExtra("db_export_location")
            if (!DbExportLocation.open(this, uri, downloads, "location")) {
                DbExportLocation.showUnavailable(this, uri, downloads, filename, location)
            }
        }
        val navTab = intent.getIntExtra("nav_tab", -1)
        val navSubTab = intent.getIntExtra("nav_subtab", -1)
        val eventType = intent.getStringExtra("nav_event_type") ?: ""
        val payloadJson = intent.getStringExtra("nav_payload_json") ?: ""
        if (navTab >= 0) {
            intent.removeExtra("nav_tab")
            intent.removeExtra("nav_subtab")
            intent.removeExtra("nav_event_type")
            intent.removeExtra("nav_payload_json")
            pendingNav = mapOf(
                "tab" to navTab,
                "sub_tab" to navSubTab,
                "event_type" to eventType,
                "payload_json" to payloadJson
            )
            // Dart 가 준비됐으면(dartReady) 그때 보낸다. 예전처럼 500ms 뒤에도 한 번 시도한다 —
            // Dart 처리기가 아직 없으면 notImplemented 로 돌아와 요청을 지우지 않는다.
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                deliverPendingNav()
            }, 500)
        }
    }

    /** 보류한 이동 요청을 Dart 로 보낸다. Dart 가 받았을 때(success/error)만 지운다. 메인 스레드에서 부른다. */
    private fun deliverPendingNav() {
        val nav = pendingNav ?: return
        val channel = methodChannel ?: return
        if (pendingNavInFlight) return
        pendingNavInFlight = true
        channel.invokeMethod("navigateToTab", nav, object : MethodChannel.Result {
            override fun success(result: Any?) = onNavDelivered(nav)
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = onNavDelivered(nav)
            override fun notImplemented() {
                // Dart 처리기가 아직 없다 — dartReady 를 기다린다.
                pendingNavInFlight = false
            }
        })
    }

    private fun onNavDelivered(nav: Map<String, Any>) {
        pendingNavInFlight = false
        if (pendingNav === nav) {
            pendingNav = null
        } else {
            // 보내는 사이 새 요청이 들어왔다.
            deliverPendingNav()
        }
    }

    private fun createAppNotifChannel() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
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

    private fun updateAppShortcuts() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        val shortcutManager = getSystemService(ShortcutManager::class.java) ?: return
        val shortcut = buildPrimaryShortcut()
        if (shortcut == null) {
            shortcutManager.removeAllDynamicShortcuts()
            return
        }
        shortcutManager.dynamicShortcuts = listOf(shortcut)
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.N_MR1)
    private fun buildPrimaryShortcut(): ShortcutInfo? {
        if (isConfiguredStandalone()) {
            return buildShortcut(
                id = QUICK_ACTION_ID,
                shortLabel = "동기화",
                longLabel = "데이터 동기화",
                eventType = EVENT_QUICK_SYNC,
            )
        }
        if (isConfiguredServer()) {
            return buildShortcut(
                id = QUICK_ACTION_ID,
                shortLabel = "크롤링",
                longLabel = "서버 크롤링 시작",
                eventType = EVENT_QUICK_CRAWL,
            )
        }
        return null
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.N_MR1)
    private fun buildShortcut(
        id: String,
        shortLabel: String,
        longLabel: String,
        eventType: String,
    ): ShortcutInfo {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            action = Intent.ACTION_VIEW
            putExtra("nav_tab", 6)
            putExtra("nav_event_type", eventType)
        } ?: Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("nav_tab", 6)
            putExtra("nav_event_type", eventType)
        }
        return ShortcutInfo.Builder(this, id)
            .setShortLabel(shortLabel)
            .setLongLabel(longLabel)
            .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(launchIntent)
            .build()
    }

    private fun isConfiguredStandalone(): Boolean {
        val appMode = flutterStringPref(PREF_APP_MODE)
        val username = flutterStringPref(PREF_STANDALONE_USERNAME)
        val isDemoMode = flutterBooleanPref(PREF_STANDALONE_DEMO_MODE)
        return appMode == "standalone" && username.isNotBlank() && !isDemoMode
    }

    private fun isConfiguredServer(): Boolean {
        val appMode = flutterStringPref(PREF_APP_MODE)
        val baseUrl = flutterStringPref(PREF_BASE_URL)
        val apiKey = flutterStringPref(PREF_API_KEY)
        return appMode != "standalone" && baseUrl.isNotBlank() && apiKey.isNotBlank()
    }

    private fun flutterStringPref(key: String): String {
        return getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(key, "") ?: ""
    }

    private fun flutterBooleanPref(key: String): Boolean {
        return getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getBoolean(key, false)
    }

    private fun showLocalNotification(
        title: String,
        body: String,
        navTab: Int? = null,
        navSubTab: Int? = null,
        eventType: String? = null,
        payloadJson: String? = null,
    ) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            data = android.net.Uri.parse("mysafetyreport://notification/app/${java.util.UUID.randomUUID()}")
            if (navTab != null) putExtra("nav_tab", navTab)
            if (navSubTab != null) putExtra("nav_subtab", navSubTab)
            if (!eventType.isNullOrEmpty()) putExtra("nav_event_type", eventType)
            if (!payloadJson.isNullOrEmpty()) putExtra("nav_payload_json", payloadJson)
        }
        val pi = PendingIntent.getActivity(
            this, notifIdGen.get(), openIntent ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif = NativeNotifications.builder(this, NOTIF_CHANNEL_APP)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify("app", notifIdGen.getAndIncrement(), notif)
    }

    /**
     * v9 EncryptedSharedPreferences 로 저장돼 아직 새 cipher 로 옮겨지지 않은 항목 수.
     * v9 ESP 항목은 이름이 암호화돼 플러그인 접두사가 없고, v10 이관이 끝나면 접두사 있는 항목과 keyset 두 줄만 남는다
     * (에뮬레이터에서 이관 전후 파일로 확인). 값은 읽지 않는다. 파일을 못 읽으면 -1(미확인 — 이관 완료로 보지 않음).
     */
    private fun unmigratedLegacySecureEntries(): Int = try {
        getSharedPreferences(SECURE_STORAGE_PREFS, MODE_PRIVATE).all.keys.count { key ->
            !key.startsWith(SECURE_STORAGE_KEY_PREFIX) && !key.startsWith(ESP_KEYSET_PREFIX) &&
                key !in SECURE_STORAGE_META_KEYS
        }
    } catch (e: Exception) {
        -1
    }

    @Deprecated("Activity callback required by the existing MethodChannel")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_REQUEST) return
        val result = exportResult ?: return
        val source = exportSource
        exportResult = null; exportSource = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || source == null) { result.success(null); return }
        Thread {
            try {
                DbExportLocation.copy(this, source, uri)
                try {
                    val read = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0
                    val write = data.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
                    if (read && write) contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    else if (read) contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    else if (write) contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                } catch (_: Exception) { }
                var filename = source.name
                contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) filename = it.getString(0)
                }
                val saved = mapOf("uri" to uri.toString(), "filename" to filename, "location" to "선택한 문서 위치: $uri", "downloads" to false)
                runOnUiThread { result.success(saved) }
            } catch (e: Exception) {
                try { android.provider.DocumentsContract.deleteDocument(contentResolver, uri) } catch (_: Exception) { }
                runOnUiThread { result.error("DB_EXPORT", e.message, null) }
            }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        communityDartReady = false
        val authChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            COMMUNITY_AUTH_CHANNEL
        )
        communityAuthChannel = authChannel
        authChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingLink" -> {
                    communityDartReady = true
                    result.success(takeCommunityAuthLink())
                }
                else -> result.notImplemented()
            }
        }

        // flutter_secure_storage 9 → 10 이관 확인(lib/services/secure_storage_migration.dart). 값은 읽지 않고 키 이름만 센다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "unmigratedLegacyEntries" -> result.success(unmigratedLegacySecureEntries())
                else -> result.notImplemented()
            }
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        syncStoppedListener = { owner, reason ->
            channel.invokeMethod("syncFgsStopped", mapOf("owner" to owner, "reason" to reason))
        }
        SyncForegroundService.stoppedListener = syncStoppedListener
        channel.setMethodCallHandler { call, result ->
                when (call.method) {

                    "publishDbExport" -> {
                        try {
                            val source = DbExportLocation.source(this, call.argument<String>("path") ?: "")
                            val filename = call.argument<String>("filename") ?: source.name
                            if (Build.VERSION.SDK_INT >= 29) {
                                Thread {
                                    try {
                                        val data = DbExportLocation.publish(this, source, filename)
                                        runOnUiThread { result.success(data) }
                                    } catch (e: Exception) { runOnUiThread { result.error("DB_EXPORT", e.message, null) } }
                                }.start()
                            } else {
                                check(exportResult == null) { "저장 위치를 선택 중입니다." }
                                exportResult = result; exportSource = source
                                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = "application/octet-stream"
                                    putExtra(Intent.EXTRA_TITLE, filename)
                                }
                                startActivityForResult(intent, EXPORT_REQUEST)
                            }
                        } catch (e: Exception) {
                            exportResult = null; exportSource = null
                            result.error("DB_EXPORT", e.message, null)
                        }
                    }
                    "openDbExport" -> result.success(DbExportLocation.open(this,
                        android.net.Uri.parse(call.argument<String>("uri") ?: ""),
                        call.argument<Boolean>("downloads") == true,
                        call.argument<String>("action") ?: "location"))
                    "notifyDbExport" -> {
                        try {
                            @Suppress("UNCHECKED_CAST")
                            DbExportLocation.notifyCompleted(this, call.arguments as Map<String, Any>)
                            result.success(null)
                        } catch (e: Exception) { result.error("DB_NOTIFY", e.message, null) }
                    }

                    "getDeviceName" -> {
                        val configured = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
                            Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                        } else null
                        result.success(configured?.takeIf { it.isNotBlank() } ?: Build.MODEL)
                    }

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
                    "processingInboxPut", "processingInboxRead", "processingInboxAck" -> {
                        Thread {
                            try {
                                val inbox = ProcessingInboxStore.get(this)
                                val value: Any? = when (call.method) {
                                    "processingInboxPut" -> {
                                        val prefix = "flutter." + (call.argument<String>("prefix") ?: "")
                                        inbox.put(prefix, call.argument<String>("value") ?: throw IllegalArgumentException("missing value"), scope = inbox.scope(getSharedPreferences(PREFS_NAME, MODE_PRIVATE), prefix))
                                    }
                                    "processingInboxRead" -> {
                                        check(!NativeProcessingRecovery.required(this)) { "processing recovery required" }
                                        inbox.read(getSharedPreferences(PREFS_NAME, MODE_PRIVATE), "flutter." + (call.argument<String>("prefix") ?: ""), call.argument<List<String>>("mirrors") ?: emptyList(), call.argument<String>("owner") ?: throw IllegalArgumentException("missing owner"))
                                    }
                                    else -> { inbox.acknowledge((call.argument<List<String>>("keys") ?: emptyList()).map { "flutter.$it" }, call.argument<String>("owner") ?: throw IllegalArgumentException("missing owner")); true }
                                }
                                runOnUiThread { result.success(value) }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("PROCESSING_INBOX_FAILED", "처리 대기 자료를 확인하지 못했습니다.", null) }
                            }
                        }.start()
                    }

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
                            stopService(Intent(this, WsService::class.java))
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
                        val payloadJson = call.argument<String>("payload_json")
                        showLocalNotification(title, body, navTab, navSubTab, eventType, payloadJson)
                        result.success(null)
                    }

                    "refreshQuickActions" -> {
                        updateAppShortcuts()
                        result.success(true)
                    }

                    // Dart 루트 처리기가 걸렸다(SQ-B05) — 보류한 알림 탭 이동 요청을 보낸다.
                    "dartReady" -> {
                        result.success(true)
                        deliverPendingNav()
                    }

                    // ── 동기화 Foreground Service 제어 ─────────────────────
                    // Flutter 가 ref counting 관리. 첫 start / 마지막 stop 만 호출됨.
                    "startSyncFgs" -> {
                        try {
                            val message = call.argument<String>("message") ?: "동기화 진행 중..."
                            val owner = call.argument<String>("owner") ?: throw IllegalArgumentException("missing owner")
                            val handler = android.os.Handler(android.os.Looper.getMainLooper())
                            val replied = java.util.concurrent.atomic.AtomicBoolean(false)
                            val timeout = Runnable { if (replied.compareAndSet(false, true)) result.error("SYNC_FGS_START_FAILED", "서비스 시작 확인 시간 초과", null) }
                            val receipt = object : android.os.ResultReceiver(handler) {
                                override fun onReceiveResult(code: Int, data: android.os.Bundle?) {
                                    if (!replied.compareAndSet(false, true)) return
                                    handler.removeCallbacks(timeout)
                                    if (code == 1) result.success(true) else result.error("SYNC_FGS_START_FAILED", "서비스 시작 실패", null)
                                }
                            }
                            val intent = Intent(this, SyncForegroundService::class.java).apply {
                                action = SyncForegroundService.ACTION_START
                                putExtra(SyncForegroundService.EXTRA_MESSAGE, message)
                                putExtra(SyncForegroundService.EXTRA_OWNER, owner)
                                putExtra(SyncForegroundService.EXTRA_RECEIPT, receipt)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            handler.postDelayed(timeout, 5_000L)
                        } catch (e: Exception) {
                            result.error("SYNC_FGS_START_FAILED", e.message, null)
                        }
                    }
                    "stopSyncFgs" -> {
                        try {
                            val owner = call.argument<String>("owner")
                            if (owner == SyncForegroundService.activeOwner) stopService(Intent(this, SyncForegroundService::class.java))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SYNC_FGS_STOP_FAILED", e.javaClass.simpleName, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        updateAppShortcuts()
        // 앱이 포그라운드로 돌아올 때 WsService 자동 시작 (설정이 완료된 경우)
        autoStartWsServiceIfConfigured()
    }

    private fun autoStartWsServiceIfConfigured() {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val appMode = prefs.getString("flutter.appMode", "server") ?: "server"
        if (appMode != "server" || !ClientGateGuard.isOpen(prefs)) {
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
