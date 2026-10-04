package com.fentanest.mysafetyreport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * 동기화 진행 중 프로세스 보호용 Foreground Service.
 *
 * Standalone 모드에서 SyncEngine.start() 또는 drainIfPending() 실행 동안
 * 프로세스 우선순위를 높인다. FlutterEngine 생존이나 작업 완료를 보장하지 않는다.
 * Activity가 소유한 엔진을 파괴할 때 서비스도 종료하고 미완료 의도를 보존한다.
 * 강제 종료·OS 종료·기기 재시작 후에는 새 실행에서 미완료 작업을 확인한다.
 *
 * Flutter 측에서 MethodChannel('startSyncFgs' / 'stopSyncFgs') 로 lifecycle 제어.
 * Ref counting 은 Flutter 쪽에서 관리.
 */
class SyncForegroundService : Service() {
    companion object {
        const val TAG = "SyncFgs"
        const val ACTION_START = "com.fentanest.mysafetyreport.SYNC_FGS_START"
        const val ACTION_STOP = "com.fentanest.mysafetyreport.SYNC_FGS_STOP"
        const val EXTRA_MESSAGE = "message"
        const val NOTIF_CHANNEL = "sync_fgs"
        const val NOTIF_ID = 4001
        const val EXTRA_OWNER = "owner"
        const val EXTRA_RECEIPT = "receipt"
        @Volatile var activeOwner: String? = null
            private set
        var stoppedListener: ((String, String) -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "동기화 진행 중..."
                val owner = intent.getStringExtra(EXTRA_OWNER)
                @Suppress("DEPRECATION")
                val receipt = intent.getParcelableExtra<android.os.ResultReceiver>(EXTRA_RECEIPT)
                try {
                    check(!owner.isNullOrEmpty())
                    startForegroundCompat(message)
                    activeOwner = owner
                    receipt?.send(1, null)
                } catch (e: Exception) {
                    receipt?.send(0, null)
                    Log.w(TAG, "FGS start failed: ${e.javaClass.simpleName}")
                    stopServiceNow("start_failed")
                }
            }
            ACTION_STOP -> {
                stopServiceNow("FGS stop requested")
            }
        }
        return START_NOT_STICKY  // 종료 시 자동 재시작 안 함 (Flutter 가 명시적으로 시작)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        val owner = activeOwner
        if (owner != null) stoppedListener?.invoke(owner, "timeout")
        stopServiceNow("timeout")
    }

    override fun onDestroy() {
        val owner = activeOwner
        activeOwner = null
        if (owner != null) stoppedListener?.invoke(owner, "destroyed")
        super.onDestroy()
    }

    private fun startForegroundCompat(message: String) {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, openIntent ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif = NativeNotifications.builder(this, NOTIF_CHANNEL)
            .setContentTitle("🔄 동기화 진행 중")
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun stopServiceNow(reason: String) {
        Log.w(TAG, reason)
        stopForegroundCompat()
        stopSelf()
    }

    private fun createChannel() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(NOTIF_CHANNEL) == null) {
            val ch = NotificationChannel(
                NOTIF_CHANNEL,
                "동기화 진행 (Standalone)",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Standalone 모드 동기화 중 프로세스 보호용 알림"
                setShowBadge(false)
                enableVibration(false)
            }
            nm.createNotificationChannel(ch)
        }
    }
}
