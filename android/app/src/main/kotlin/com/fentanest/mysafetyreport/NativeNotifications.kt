package com.fentanest.mysafetyreport

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build

object NativeNotifications {
    fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, channel)
        else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

    // ── 변경 알림 태그 (2026-10-18) ──────────────────────────────────────────
    // 신고·중복군 변경 알림은 대상별 태그(+고정 ID)로 띄운다. 앱 안에서 그 신고를 읽으면(상세 시트·알림 기록·
    // 푸시 탭) Dart 가 같은 태그로 지운다 — 예전에는 시스템 알림을 지우는 경로가 없어 하나씩 눌러야 사라졌다.
    // 같은 신고의 새 변경 알림은 앞 알림을 대신한다(태그·ID 가 같음). PendingIntent requestCode 는 따로 고유하게 둔다.

    const val CHANGE_NOTIF_ID = 1
    private const val TAG_REPORT = "sr-report:"
    private const val TAG_DUPLICATE = "sr-dup:"

    /** 신고번호 정규화 — Dart `NotificationHistoryProvider.normalizeReportNumber`(trim + 대문자)와 같다. */
    private fun normalize(value: String): String = value.trim().uppercase()

    private fun text(o: org.json.JSONObject, key: String): String {
        if (o.isNull(key)) return ""
        return o.optString(key, "").trim()
    }

    /** 변경 payload 의 알림 태그. 신고번호·중복군 ID 가 없으면 null(호출자가 예전 태그를 쓴다). */
    fun changeTag(payloadJson: String?): String? {
        if (payloadJson.isNullOrEmpty()) return null
        return try {
            val o = org.json.JSONObject(payloadJson)
            if (text(o, "notification_kind") == "duplicate") {
                text(o, "group_id").takeIf { it.isNotEmpty() }?.let { TAG_DUPLICATE + it }
            } else {
                normalize(text(o, "신고번호")).takeIf { it.isNotEmpty() }?.let { TAG_REPORT + it }
            }
        } catch (_: Exception) {
            null
        }
    }

    /** 앱이 띄운 결과·변경 알림 태그(포그라운드 서비스 알림은 태그가 없어 여기에 걸리지 않는다). */
    private fun isAppResultTag(tag: String): Boolean =
        tag == "ws-push" || tag == "app" || tag.startsWith("notification-result-") ||
            tag.startsWith(TAG_REPORT) || tag.startsWith(TAG_DUPLICATE)

    /**
     * 읽은 신고·중복군의 알림을 지운다. [all] 이면 앱이 띄운 결과·변경 알림 전부(크롤링 시작·완료, 묶음 알림 포함).
     * 지운 수를 돌려준다.
     */
    fun cancelRead(
        context: Context,
        reportNumbers: Collection<String>,
        groupIds: Collection<String>,
        all: Boolean,
    ): Int {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val tags = reportNumbers.map { TAG_REPORT + normalize(it) }.toSet() +
            groupIds.map { TAG_DUPLICATE + it.trim() }.toSet()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            tags.forEach { nm.cancel(it, CHANGE_NOTIF_ID) }
            return tags.size
        }
        var cancelled = 0
        for (sbn in nm.activeNotifications) {
            val tag = sbn.tag ?: continue
            if (tag in tags || (all && isAppResultTag(tag))) {
                nm.cancel(tag, sbn.id)
                cancelled++
            }
        }
        return cancelled
    }
}
