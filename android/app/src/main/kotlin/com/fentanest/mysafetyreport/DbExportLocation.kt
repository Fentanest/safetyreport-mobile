package com.fentanest.mysafetyreport

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.DocumentsContract
import java.io.File

/** Only finalized export snapshots in the app cache can be published. */
object DbExportLocation {
    private const val DIRECTORY = "Download/mysafetyreport/"
    fun source(context: Context, path: String): File {
        val file = File(path).canonicalFile
        require(file.path.startsWith(context.cacheDir.canonicalPath + File.separator)) {
            "내보내기 임시 사본만 저장할 수 있습니다."
        }
        require(file.isFile && file.length() > 0 && file.extension == "db") { "완료된 DB 내보내기가 없습니다." }
        return file
    }

    fun publish(context: Context, source: File, filename: String): Map<String, Any> {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, File(filename).name)
            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
            put(MediaStore.Downloads.RELATIVE_PATH, DIRECTORY)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: error("다운로드 저장 위치를 만들 수 없습니다.")
        try {
            copy(context, source, uri)
            val completed = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            check(resolver.update(uri, completed, null, null) == 1)
            var actualName = File(filename).name
            var actualLocation = DIRECTORY
            resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME, MediaStore.Downloads.RELATIVE_PATH), null, null, null)?.use {
                if (it.moveToFirst()) { actualName = it.getString(0); actualLocation = it.getString(1) }
            }
            return mapOf("uri" to uri.toString(), "filename" to actualName, "location" to actualLocation, "downloads" to true)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    fun copy(context: Context, source: File, uri: Uri) {
        val output = context.contentResolver.openOutputStream(uri, "w") ?: error("파일을 쓸 수 없습니다.")
        output.use { out -> source.inputStream().use { input -> input.copyTo(out, 64 * 1024) }; out.flush() }
        val size = context.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize }
        check(size == null || size < 0 || size == source.length()) { "파일 저장이 중간에 끊겼습니다." }
    }

    fun locationIntent(context: Context, uri: Uri, downloads: Boolean): Intent {
        // Ask the provider for its real document URI; never fabricate an ID/path.
        val document = if (!downloads) uri else try {
            if (Build.VERSION.SDK_INT >= 29) MediaStore.getDocumentUri(context, uri) else null
        } catch (_: Exception) { null }
        if (document == null) return Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            if (Build.VERSION.SDK_INT >= 26) putExtra(DocumentsContract.EXTRA_INITIAL_URI, document)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    fun open(context: Context, uri: Uri, downloads: Boolean, action: String): Boolean = try {
        val intent = when (action) {
            "share" -> Intent(Intent.ACTION_SEND).apply {
                type = "application/octet-stream"; putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            "file" -> Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/octet-stream")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            else -> locationIntent(context, uri, downloads)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        if (action != "location") false else try {
            context.startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }); true
        } catch (_: Exception) { false }
    }

    fun notifyCompleted(context: Context, data: Map<String, Any>) {
        val uri = Uri.parse(data["uri"] as String)
        val intent = Intent(context, MainActivity::class.java).apply {
            putExtra("db_export_uri", uri.toString())
            putExtra("db_export_downloads", data["downloads"] == true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val id = uri.toString().hashCode()
        val pi = PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel("db_exports", "DB 저장 완료", NotificationManager.IMPORTANCE_DEFAULT))
        manager.notify(id, Notification.Builder(context, "db_exports")
            .setSmallIcon(R.drawable.ic_stat_logo).setContentTitle("DB 저장 완료: ${data["filename"]}")
            .setContentText("${data["location"]} · 눌러 저장 위치 열기").setContentIntent(pi).setAutoCancel(true).build())
    }
}
