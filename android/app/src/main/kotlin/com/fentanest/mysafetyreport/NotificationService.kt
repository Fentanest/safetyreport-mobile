package com.fentanest.mysafetyreport

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.app.Notification
import android.util.Log

/** Persist before admission checks: a stale gate or unavailable network is retryable. */
class NotificationService : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        NotificationWork.schedule(this)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!NotificationReports.accepts(sbn.packageName)) return
        val extras = sbn.notification.extras
        val parts = listOf(
            extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString(" "),
        )
        val reports = NotificationReports.extract(parts)
        if (reports.isEmpty()) return
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val standalone = prefs.getString("flutter.appMode", "server") == "standalone"
            if (standalone && prefs.getBoolean("flutter.standaloneDemoMode", false)) return
            val prefix = if (standalone) PrefsInbox.QUEUE else PrefsInbox.ENQUEUE
            val inbox = ProcessingInboxStore.get(this)
            for (number in reports) inbox.putNotification(prefs, prefix, number, packageName = sbn.packageName)
            NotificationWork.notice(this, "답변 알림 처리 대기", "자동 처리를 예약했습니다. 연결이나 인증 확인이 늦어지면 재시도합니다.")
            NotificationWork.schedule(this)
        } catch (_: Exception) {
            runCatching { NativeProcessingRecovery.mark(this) }
            NotificationWork.notice(this, "자동 처리 확인 필요", "알림 처리 대기를 저장하거나 예약하지 못했습니다. 앱을 열어 확인해 주세요.")
            Log.w("SafetyReportNS", "notification processing could not be scheduled")
        }
    }
}
