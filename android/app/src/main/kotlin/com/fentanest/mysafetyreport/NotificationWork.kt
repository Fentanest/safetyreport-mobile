package com.fentanest.mysafetyreport

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.*
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** OS-owned lifetime: works without an Activity, retries after process death/network loss. */
class NotificationWork(context: Context, params: WorkerParameters) : ListenableWorker(context, params) {
    companion object {
        private const val CHANNEL = "notification_processing"
        private const val NOTICE_ID = 7302
        private val active = AtomicBoolean(false)
        private const val UNIQUE = "notification-processing"
        private val scheduler = Executors.newSingleThreadExecutor()

        /**
         * 새 답변 알림 도착(2026-10-12 redroid 실측): KEEP 만 쓰면 앞선 실패의 지수 대기(최대 5시간) 중인 작업에
         * 새 알림이 묶여 그만큼 늦게 처리된다. 대기 중(ENQUEUED)이면 REPLACE 로 바로 다시 예약하고, 실행 중이면
         * APPEND_OR_REPLACE 로 끝난 직후 한 번 더 돌게 한다(실행 중 작업이 새 항목을 못 봤을 수 있으므로).
         */
        fun scheduleFresh(context: Context) {
            val app = context.applicationContext
            val manager = WorkManager.getInstance(app)
            val infos = manager.getWorkInfosForUniqueWork(UNIQUE)
            infos.addListener({
                val running = runCatching { infos.get().any { it.state == WorkInfo.State.RUNNING } }.getOrDefault(false)
                runCatching {
                    manager.enqueueUniqueWork(UNIQUE,
                        if (running) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.REPLACE, oneTime().build())
                    schedule(app)
                }
            }, scheduler)
        }

        private fun oneTime(): OneTimeWorkRequest.Builder {
            val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            val request = OneTimeWorkRequest.Builder(NotificationWork::class.java)
                .setConstraints(constraints).setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            // Pre-S expedited jobs need an FGS. Use regular jobs there instead.
            if (Build.VERSION.SDK_INT >= 31) request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            return request
        }

        fun schedule(context: Context, renewGate: Boolean = false) {
            if (renewGate) context.getSharedPreferences("NotificationWork", Context.MODE_PRIVATE)
                .edit().putBoolean("renew_gate", true).commit()
            val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            val manager = WorkManager.getInstance(context)
            manager.enqueueUniqueWork(UNIQUE, ExistingWorkPolicy.KEEP, oneTime().build())
            // Also covers the KEEP/worker-finish race and a crash between inbox persistence and enqueue.
            manager.enqueueUniquePeriodicWork("notification-processing-recovery", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequest.Builder(NotificationWork::class.java, 15, TimeUnit.MINUTES)
                    .setConstraints(constraints).build())
        }
        fun notice(context: Context, title: String, body: String) {
            runCatching {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(CHANNEL, "자동 알림 처리", NotificationManager.IMPORTANCE_DEFAULT))
                val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                    putExtra("nav_tab", 6)
                }
                val builder = NativeNotifications.builder(context, CHANNEL).setSmallIcon(R.drawable.ic_stat_logo)
                    .setContentTitle(title).setContentText(body).setAutoCancel(true).setOnlyAlertOnce(true)
                if (intent != null) builder.setContentIntent(PendingIntent.getActivity(context, NOTICE_ID, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                nm.notify("notification-work", NOTICE_ID, builder.build())
            }
        }
    }
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var engine: FlutterEngine? = null
    private var completion: CallbackToFutureAdapter.Completer<Result>? = null
    private val finished = AtomicBoolean(false)
    private var admitted = false
    private var hadPending = false
    private val owners = mutableSetOf<String>()
    private val prefs get() = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private var stamp = ""
    private val timeout = Runnable { finish(false) }

    override fun startWork(): ListenableFuture<Result> = CallbackToFutureAdapter.getFuture { callback ->
        completion = callback
        main.post {
            if (finished.get()) return@post
            admitted = active.compareAndSet(false, true)
            if (!admitted) { finish(false); return@post }
            try {
                stamp = ClientGateGuard.configStamp(prefs)
                val prefix = if (prefs.getString("flutter.appMode", "server") == "standalone") PrefsInbox.QUEUE else PrefsInbox.ENQUEUE
                val renew = prefix == PrefsInbox.ENQUEUE && ClientGateGuard.canRenew(prefs) &&
                    applicationContext.getSharedPreferences("NotificationWork", Context.MODE_PRIVATE).getBoolean("renew_gate", false)
                hadPending = ProcessingInboxStore.get(applicationContext).hasPending(prefs, prefix)
                if (!renew && !hadPending) {
                    finish(true); return@post
                }
                main.postDelayed(timeout, 8 * 60_000L)
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
                    if (finished.get()) return@ensureInitializationCompleteAsync
                    try {
                        val flutter = FlutterEngine(applicationContext)
                        engine = flutter
                        val channel = MethodChannel(flutter.dartExecutor.binaryMessenger, "com.fentanest.mysafetyreport/permissions")
                        channel.setMethodCallHandler { call, result ->
                            if (call.method == "notificationWorkFinish") {
                                result.success(null)
                                finish(call.argument<Boolean>("success") == true && stamp == ClientGateGuard.configStamp(prefs))
                                return@setMethodCallHandler
                            }
                            if (finished.get() || stamp != ClientGateGuard.configStamp(prefs)) {
                                result.error("SCOPE_CHANGED", "설정 또는 계정이 변경되었습니다.", null)
                                return@setMethodCallHandler
                            }
                            if (call.method == "notificationWorkCommitGateCache") {
                                val raw = call.argument<String>("cache") ?: ""
                                val cache = runCatching { org.json.JSONObject(raw) }.getOrNull()
                                if (cache?.optString("state") != "ok" || cache.optString("owner") != ClientGateGuard.ownerScope(prefs)) {
                                    result.error("SCOPE_CHANGED", "인증 범위가 변경되었습니다.", null)
                                } else if (!prefs.edit().putString("flutter.community_gate_cache_v1", raw).commit()) {
                                    result.error("CACHE_WRITE_FAILED", "인증 확인을 저장하지 못했습니다.", null)
                                } else { result.success(null) }
                                return@setMethodCallHandler
                            }
                            if (call.method == "notificationWorkPending") {
                                val prefix = if (prefs.getString("flutter.appMode", "server") == "standalone") PrefsInbox.QUEUE else PrefsInbox.ENQUEUE
                                result.success(ProcessingInboxStore.get(applicationContext).hasPending(prefs, prefix)); return@setMethodCallHandler
                            }
                            if (call.method == "notificationWorkScope") {
                                result.success(stamp); return@setMethodCallHandler
                            }
                            if (call.method == "showNotification") {
                                try { showResult(call); result.success(null) }
                                catch (_: Exception) { result.error("NOTIFICATION_FAILED", "결과 알림을 표시하지 못했습니다.", null) }
                                return@setMethodCallHandler
                            }
                            io.execute {
                                try {
                                    check(!finished.get() && stamp == ClientGateGuard.configStamp(prefs))
                                    val inbox = ProcessingInboxStore.get(applicationContext)
                                    val value: Any? = when (call.method) {
                                        "processingInboxPut" -> {
                                            val prefix = "flutter." + (call.argument<String>("prefix") ?: "")
                                            inbox.put(prefix, call.argument<String>("value") ?: error("missing value"), scope = inbox.scope(prefs, prefix))
                                        }
                                        "processingInboxRead" -> {
                                            check(!NativeProcessingRecovery.required(applicationContext))
                                            val owner = call.argument<String>("owner") ?: error("missing owner")
                                            synchronized(owners) { owners.add(owner) }
                                            inbox.read(prefs, "flutter." + (call.argument<String>("prefix") ?: ""), call.argument<List<String>>("mirrors") ?: emptyList(), owner)
                                        }
                                        "processingInboxAck" -> {
                                            val keys = (call.argument<List<String>>("keys") ?: emptyList()).map { "flutter.$it" }
                                            inbox.acknowledge(keys, call.argument<String>("owner") ?: error("missing owner"))
                                            val count = keys.count { it.startsWith(PrefsInbox.ENQUEUE) }
                                            if (count > 0) prefs.edit()
                                                .putInt("flutter.auto_enqueue_count", prefs.getInt("flutter.auto_enqueue_count", 0) + count)
                                                .putLong("flutter.auto_enqueue_last_at", System.currentTimeMillis()).commit()
                                            true
                                        }
                                        else -> null
                                    }
                                    main.post { if (value == null) result.notImplemented() else result.success(value) }
                                } catch (_: Exception) {
                                    main.post { result.error("PROCESSING_INBOX_FAILED", "처리 대기를 확인하지 못했습니다.", null) }
                                }
                            }
                        }
                        flutter.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "notificationBackgroundMain"))
                    } catch (_: Exception) { finish(false) }
                }
            } catch (_: Exception) { finish(false) }
        }
        "notification-processing"
    }

    private fun showResult(call: io.flutter.plugin.common.MethodCall) {
        val context = applicationContext
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = "app_push_v2"
        if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel(channel, "앱 알림", NotificationManager.IMPORTANCE_HIGH))
        val eventId = java.util.UUID.randomUUID().toString()
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            data = android.net.Uri.parse("mysafetyreport://notification/app/$eventId")
            call.argument<Int>("nav_tab")?.let { putExtra("nav_tab", it) }
            call.argument<Int>("nav_subtab")?.let { putExtra("nav_subtab", it) }
            call.argument<String>("event_type")?.let { putExtra("nav_event_type", it) }
            call.argument<String>("payload_json")?.let { putExtra("nav_payload_json", it) }
        }
        val body = call.argument<String>("body") ?: ""
        val builder = NativeNotifications.builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_logo).setContentTitle(call.argument<String>("title") ?: "동기화")
            .setContentText(body).setStyle(android.app.Notification.BigTextStyle().bigText(body)).setAutoCancel(true)
        if (intent != null) builder.setContentIntent(PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        nm.notify("notification-result-$eventId", 0, builder.build())
    }

    private fun finish(success: Boolean) {
        if (!finished.compareAndSet(false, true)) return
        main.removeCallbacks(timeout)
        engine?.destroy()
        engine = null
        // Release claims only after the isolate is gone; OS stop never ACKs unfinished work.
        io.execute {
            runCatching {
                val inbox = ProcessingInboxStore.get(applicationContext)
                synchronized(owners) { owners.forEach { inbox.release(it) } }
            }
            main.post {
                if (admitted) active.set(false)
                if (success) {
                    if (hadPending) notice(applicationContext, "자동 처리 요청 완료", if (prefs.getString("flutter.appMode", "server") == "standalone") "대기 신고 동기화를 완료했습니다." else "서버가 크롤링 요청을 접수했습니다. 결과는 크롤링 현황에서 확인할 수 있습니다.")
                    applicationContext.getSharedPreferences("NotificationWork", Context.MODE_PRIVATE).edit().remove("renew_gate").commit()
                } else if (admitted) {
                    notice(applicationContext, "자동 처리 재시도 대기", "연결·인증 또는 처리 상태를 확인하지 못했습니다. 자동 재시도하며, 앱에서 상태를 확인할 수 있습니다.")
                }
                completion?.set(if (success) Result.success() else Result.retry())
                io.shutdown()
            }
        }
    }
    override fun onStopped() { main.post { finish(false) } }
}
