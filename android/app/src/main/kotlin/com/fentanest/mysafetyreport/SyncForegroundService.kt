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
 * activity 가 destroy 되어도 프로세스가 즉시 OS kill 되지 않도록 우선순위 격상.
 *   ✓ Recent apps swipe-away → 거의 안 죽음
 *   ✓ 메모리 부족 OS kill → 가장 마지막에 후보
 *   ✗ 설정 → 강제종료 / Adb kill → 막을 수 없음
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
                startForegroundCompat(message)
                Log.i(TAG, "FGS started: $message")
            }
            ACTION_STOP -> {
                stopServiceNow("FGS stop requested")
            }
        }
        return START_NOT_STICKY  // 종료 시 자동 재시작 안 함 (Flutter 가 명시적으로 시작)
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopServiceNow("FGS timed out: startId=$startId, fgsType=$fgsType")
    }

    private fun startForegroundCompat(message: String) {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, openIntent ?: Intent(),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif = Notification.Builder(this, NOTIF_CHANNEL)
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
