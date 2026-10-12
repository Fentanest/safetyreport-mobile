package com.fentanest.mysafetyreport

import android.app.Application
import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class, sdk = [28])
class SecureStorageRecoveryTest {
    @Test fun resetClearsOnlySecureStorageIncludingLegacyKeysets() {
        val context = RuntimeEnvironment.getApplication()
        val secure = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
        secure.edit().putString("legacy_ciphertext", "fixture")
            .putString("__androidx_security_crypto_encrypted_prefs_key_keyset__", "fixture").commit()
        val pluginMetadata = listOf("FlutterSecureKeyStorage", "FlutterSecureStorageConfiguration",
            "FlutterSecureStorageConfiguration:FlutterSecureStorage").map {
            context.getSharedPreferences(it, Context.MODE_PRIVATE).apply {
                edit().putString("old_cipher_metadata", "fixture").commit()
            }
        }
        val unrelated = context.getSharedPreferences("FlutterSecureStorage:other", Context.MODE_PRIVATE)
        unrelated.edit().putString("keep", "fixture").commit()
        val settings = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        settings.edit().putString("flutter.appMode", "standalone").commit()
        val databases = listOf("standalone_reports.db", "community.db").map {
            context.openOrCreateDatabase(it, Context.MODE_PRIVATE, null).apply {
                execSQL("CREATE TABLE IF NOT EXISTS preserved(value TEXT)")
                execSQL("INSERT INTO preserved VALUES ('fixture')")
            }
        }
        try {
            assertTrue(SecureStorageRecovery.reset(context))
            assertTrue(secure.all.isEmpty())
            pluginMetadata.forEach { assertTrue(it.all.isEmpty()) }
            assertEquals("fixture", unrelated.getString("keep", null))
            assertEquals("standalone", settings.getString("flutter.appMode", null))
            databases.forEach { db -> db.rawQuery("SELECT value FROM preserved", null).use {
                assertTrue(it.moveToFirst()); assertEquals("fixture", it.getString(0))
            } }
        } finally { databases.forEach { it.close() } }
    }
}
