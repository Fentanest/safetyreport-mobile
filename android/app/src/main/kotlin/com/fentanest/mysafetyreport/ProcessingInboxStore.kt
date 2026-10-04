package com.fentanest.mysafetyreport

import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.content.ContentValues
import java.util.UUID

/** Private processing obligations. History retention never removes pending work.
 * ACK receipts survive a crash between the SQLite ACK and Dart mirror removal.
 */
class ProcessingInboxStore private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, "processing_inbox.db", null, 1) {
    companion object {
        @Volatile private var instance: ProcessingInboxStore? = null
        fun get(context: Context): ProcessingInboxStore = instance ?: synchronized(this) {
            instance ?: ProcessingInboxStore(context).also { instance = it }
        }
        private val prefixes = setOf(PrefsInbox.QUEUE, PrefsInbox.PENDING, PrefsInbox.ENQUEUE)
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, event_key TEXT UNIQUE NOT NULL, prefix TEXT NOT NULL, value TEXT NOT NULL, scope TEXT NOT NULL, terminal INTEGER NOT NULL DEFAULT 0, claim_owner TEXT, claim_until INTEGER NOT NULL DEFAULT 0)")
        db.execSQL("CREATE INDEX processing_pending ON events(prefix,terminal,seq)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        throw IllegalStateException("unsupported processing inbox version")
    }

    fun scope(prefs: SharedPreferences, prefix: String): String {
        val raw = if (prefix == PrefsInbox.QUEUE) "standalone:" + (prefs.getString("flutter.standaloneUsername", "") ?: "") + ":" + ClientGateGuard.ownerScope(prefs)
            else ClientGateGuard.configStamp(prefs)
        return java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    @Synchronized fun put(prefix: String, value: String, key: String? = null, scope: String): String {
        require(prefix in prefixes)
        val eventKey = key ?: prefix + "native." + System.currentTimeMillis().toString().padStart(15, '0') + "_" + UUID.randomUUID()
        val row = ContentValues().apply {
            put("event_key", eventKey); put("prefix", prefix); put("value", value); put("scope", scope)
        }
        val inserted = writableDatabase.insertWithOnConflict("events", null, row, SQLiteDatabase.CONFLICT_IGNORE)
        if (inserted == -1L) {
            readableDatabase.query("events", arrayOf("value", "scope"), "event_key=?", arrayOf(eventKey), null, null, null).use { c ->
                check(c.moveToFirst() && c.getString(0) == value && c.getString(1) == scope) { "processing event not preserved" }
            }
        }
        return eventKey
    }

    /** Copy -> SQLite commit -> receipt. Retain unverified legacy; never re-import mirrors. */
    @Synchronized private fun migrate(prefs: SharedPreferences, prefix: String) {
        val legacyKey = when (prefix) {
            PrefsInbox.QUEUE -> "flutter.standalone_pending_reports"
            PrefsInbox.PENDING -> "flutter.pending_crawl_changes"
            else -> null
        }
        if (legacyKey != null) {
            val raw = prefs.getString(legacyKey, null)
            if (!raw.isNullOrBlank() && raw != "[]") {
                put(prefix, raw, prefix + "native.legacy_scalar", "legacy-unverified")
            }
        }
        prefs.all.filterKeys { it.startsWith(prefix) && !it.startsWith(prefix + "native.") }.forEach { (key, raw) ->
            if (raw !is String) throw IllegalStateException("invalid legacy processing event")
            val mirrorKey = prefix + "native.legacy_" + key.removePrefix(prefix)
            put(prefix, raw, mirrorKey, "legacy-unverified")
            // Legacy removal is gated on native crash/migration runtime validation.
        }
    }

    @Synchronized fun read(prefs: SharedPreferences, prefix: String, mirrors: List<String>, owner: String): Map<String, Any> {
        require(prefix in prefixes)
        require(owner.isNotBlank())
        migrate(prefs, prefix)
        val currentScope = scope(prefs, prefix)
        val pending = mutableListOf<Map<String, String>>()
        val db = writableDatabase
        val now = System.currentTimeMillis()
        db.beginTransaction()
        try {
            db.query("events", arrayOf("event_key", "value"), "prefix=? AND terminal=0 AND scope=? AND (claim_owner IS NULL OR claim_owner=? OR claim_until<=?)", arrayOf(prefix, currentScope, owner, now.toString()), null, null, "seq", "200").use { c ->
                while (c.moveToNext()) {
                    val key = c.getString(0)
                    pending.add(mapOf("key" to key.removePrefix("flutter."), "value" to c.getString(1)))
                    db.update("events", ContentValues().apply { put("claim_owner", owner); put("claim_until", now + 600_000L) }, "event_key=?", arrayOf(key))
                }
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        val acknowledged = mirrors.filter { key ->
            readableDatabase.query("events", arrayOf("terminal", "scope"), "event_key=?", arrayOf("flutter.$key"), null, null, null).use { c -> c.moveToFirst() && (c.getInt(0) == 1 || c.getString(1) != currentScope) }
        }
        val migrated = prefs.all.keys.filter { it.startsWith(prefix) && !it.startsWith(prefix + "native.") }.filter { legacy ->
            readableDatabase.query("events", arrayOf("event_key"), "event_key=?", arrayOf(prefix + "native.legacy_" + legacy.removePrefix(prefix)), null, null, null).use { it.moveToFirst() }
        }.map { it.removePrefix("flutter.") }
        val blockedLegacy = readableDatabase.rawQuery("SELECT COUNT(*) FROM events WHERE prefix=? AND terminal=0 AND scope='legacy-unverified'", arrayOf(prefix)).use { it.moveToFirst(); it.getInt(0) }
        val blockedScope = readableDatabase.rawQuery("SELECT COUNT(*) FROM events WHERE prefix=? AND terminal=0 AND scope<>? AND scope<>'legacy-unverified'", arrayOf(prefix, currentScope)).use { it.moveToFirst(); it.getInt(0) }
        return mapOf("pending" to pending, "acknowledged" to acknowledged, "migrated" to migrated, "blockedLegacy" to blockedLegacy, "blockedScope" to blockedScope)
    }

    @Synchronized fun acknowledge(keys: List<String>, owner: String? = null) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            keys.forEach { key ->
                require(prefixes.any { key.startsWith(it + "native.") })
                if (owner == null) {
                    require(key.startsWith(PrefsInbox.ENQUEUE + "native."))
                    db.update("events", ContentValues().apply { put("terminal", 1) }, "event_key=?", arrayOf(key))
                } else {
                    val changed = db.update("events", ContentValues().apply { put("terminal", 1) }, "event_key=? AND claim_owner=? AND claim_until>?", arrayOf(key, owner, System.currentTimeMillis().toString()))
                    if (changed != 1) {
                        db.query("events", arrayOf("terminal"), "event_key=?", arrayOf(key), null, null, null).use { c -> check(c.moveToFirst() && c.getInt(0) == 1) { "processing claim lost" } }
                    }
                }
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
}
