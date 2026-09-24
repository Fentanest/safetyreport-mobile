package com.fentanest.mysafetyreport

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

/**
 * Standalone 하루 1회 로그인 점검(Dart `BackgroundLoginCheck`) 결과를 알림으로 띄운다.
 *
 * 점검은 WorkManager 백그라운드 Flutter 엔진에서 돈다. 그 엔진에는 MainActivity 의 MethodChannel 이
 * 없으므로, Dart 가 `flutter.standalone_auth_alert` 키를 쓰면 같은 프로세스의 이 리스너가 받아서 띄운다.
 * WorkManager 가 앱 프로세스를 새로 띄워도 Application.onCreate 가 먼저 돌므로 리스너가 등록돼 있다.
 */
class SafetyReportApplication : Application() {

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        /** Dart `AppPrefsKeys.standaloneAuthAlert` 와 같은 키(`flutter.` prefix). */
        const val PREF_AUTH_ALERT = "flutter.standalone_auth_alert"
        private const val CHANNEL_ID = "app_push_v2" // MainActivity NOTIF_CHANNEL_APP 과 같은 채널
        private const val NOTIF_ID = 7301
    }

    // SharedPreferences 는 리스너를 약한 참조로 들고 있으므로 필드로 붙잡아 둔다.
    private val authAlertListener =
        SharedPreferences.OnSharedPreferenceChangeListener { prefs, key ->
            if (key != PREF_AUTH_ALERT) return@OnSharedPreferenceChangeListener
            val raw = prefs.getString(key, null) ?: return@OnSharedPreferenceChangeListener
            val message = raw.substringAfter('|', "").ifBlank {
                "안전신문고 로그인에 실패했습니다."
            }
            showReloginNotification(message)
        }

    override fun onCreate() {
        super.onCreate()
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .registerOnSharedPreferenceChangeListener(authAlertListener)
    }

    private fun showReloginNotification(message: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "앱 알림", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "크롤링 완료 등 앱 이벤트 알림"
                    enableVibration(true)
                }
            )
        }
        // 앱을 열면 대시보드 맨 위 '재로그인 필요' 경고에서 바로 재로그인할 수 있다.
        val openIntent = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val pi = PendingIntent.getActivity(
            this, NOTIF_ID, openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val body = "$message\n앱을 열어 재로그인해 주세요."
        val notif = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("🔐 안전신문고 재로그인 필요")
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()
        nm.notify(NOTIF_ID, notif)
    }
}
