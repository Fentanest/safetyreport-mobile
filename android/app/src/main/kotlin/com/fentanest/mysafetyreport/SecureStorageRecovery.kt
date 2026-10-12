package com.fentanest.mysafetyreport

import android.content.Context

/** Only invoked after explicit confirmation, before the storage plugin is opened. */
internal object SecureStorageRecovery {
    // flutter_secure_storage 11.2.0 defaults. No app settings, other namespaces or DBs.
    // Old algorithm markers or wrapped AES keys can otherwise prevent a fresh v11 open.
    private val preferenceFiles = listOf(
        "FlutterSecureStorage",
        "FlutterSecureKeyStorage",
        "FlutterSecureStorageConfiguration",
        "FlutterSecureStorageConfiguration:FlutterSecureStorage",
    )

    fun reset(context: Context): Boolean {
        for (name in preferenceFiles) {
            if (!context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()) {
                return false
            }
        }
        return true
    }
}
