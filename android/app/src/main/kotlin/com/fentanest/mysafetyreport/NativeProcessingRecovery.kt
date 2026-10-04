package com.fentanest.mysafetyreport

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/** Never put notification contents or credentials in a recovery log. */
object NativeProcessingRecovery {
    private const val PREFS = "NativeProcessingRecovery"
    fun required(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("required", false)

    fun mark(context: Context) {
        check(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("required", true).commit())
        Log.w("ProcessingRecovery", "processing storage needs recovery; no completion acknowledged")
    }

    /** Preserve the original bytes before removing a malformed Flutter list. */
    fun quarantine(context: Context, raw: String) {
        val directory = File(context.filesDir, "processing-quarantine")
        check(directory.isDirectory || directory.mkdirs())
        val id = UUID.randomUUID().toString()
        val temporary = File(directory, "$id.part")
        FileOutputStream(temporary).use { output ->
            output.write(raw.toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        check(temporary.renameTo(File(directory, "$id.raw")))
    }
}
