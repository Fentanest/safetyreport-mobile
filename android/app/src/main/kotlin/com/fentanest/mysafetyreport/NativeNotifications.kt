package com.fentanest.mysafetyreport

import android.app.Notification
import android.content.Context
import android.os.Build

object NativeNotifications {
    fun builder(context: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, channel)
        else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
}
