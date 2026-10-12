package com.fentanest.mysafetyreport

import android.content.Context
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.content.ContentValues
import java.util.UUID
import io.flutter.plugins.sharedpreferences.JSON_LIST_PREFIX
import io.flutter.plugins.sharedpreferences.LIST_PREFIX
import io.flutter.plugins.sharedpreferences.ListEncoder
import org.json.JSONArray

/** Private processing obligations. History retention never removes pending work.
 * ACK receipts survive a crash between the SQLite ACK and Dart mirror removal.
 */
class ProcessingInboxStore private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, "processing_inbox.db", null, 2) {
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
        createNotificationReceipts(db)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        check(oldVersion == 1 && newVersion == 2)
        createNotificationReceipts(db)
    }

    private fun createNotificationReceipts(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE notification_receipts (fingerprint TEXT PRIMARY KEY, created_at INTEGER NOT NULL)")
    }

    /** Two-minute, persistent report identity. Summary text/count changes are not new answers. */
    @Synchronized fun putNotification(prefs: SharedPreferences, prefix: String, number: String, packageName: String) {
        require(NotificationReports.accepts(packageName))
        if (prefix == PrefsInbox.ENQUEUE) refreshUncertain(prefs)
        val scope = scope(prefs, prefix)
        val fingerprint = java.security.MessageDigest.getInstance("SHA-256")
            .digest("$scope|$prefix|$packageName|$number".toByteArray()).joinToString("") { "%02x".format(it) }
        val now = System.currentTimeMillis()
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("notification_receipts", "created_at<? OR created_at>?", arrayOf((now - 120_000L).toString(), now.toString()))
            val duplicate = db.rawQuery("SELECT 1 FROM notification_receipts WHERE fingerprint=?", arrayOf(fingerprint)).use { it.moveToFirst() }
            if (!duplicate) {
                // Child + group summary can describe the same report with different text.
                // Coalesce only unclaimed work; an event after the receipt window
                // must survive even when an earlier fetch is still in progress.
                val queued = db.rawQuery("SELECT 1 FROM events WHERE prefix=? AND scope=? AND value=? AND terminal=0 AND claim_owner IS NULL${retryableFilter(prefix)} AND event_key LIKE ? LIMIT 1",
                    arrayOf(prefix, scope, number, prefix + "native.notification.%")).use { it.moveToFirst() }
                if (!queued) put(prefix, number, prefix + "native.notification." + UUID.randomUUID(), scope)
                db.insertOrThrow("notification_receipts", null, ContentValues().apply { put("fingerprint", fingerprint); put("created_at", now) })
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    // Old Client enqueue receipts have no idempotent server request identity.
    // Preserve them, but never let them wake a worker or occupy its claim batch.
    // Standalone QUEUE entries (including timestamp keys) are still actionable.
    private fun retryableFilter(prefix: String): String =
        if (prefix == PrefsInbox.ENQUEUE) " AND event_key GLOB '${PrefsInbox.ENQUEUE}native.notification.*' AND event_key NOT IN (SELECT event_key FROM legacy_uncertain)" else ""

    // Rebuild a connection-local index from the durable pre-POST markers on every
    // queue decision, including the worker's pre-engine check after process death.
    // No successful ACK, deletion, or permanent schema change is implied here.
    private fun refreshUncertain(prefs: SharedPreferences) {
        val all = prefs.all
        val rawSent = all["flutter.crawl_legacy_enqueue_sent_keys"] as? String
        val sent = when {
            rawSent == null -> emptySet()
            rawSent.startsWith(JSON_LIST_PREFIX) -> JSONArray(rawSent.removePrefix(JSON_LIST_PREFIX)).let { array ->
                (0 until array.length()).map { array.getString(it) }.toSet()
            }
            rawSent.startsWith(LIST_PREFIX) -> ListEncoder().decode(rawSent.removePrefix(LIST_PREFIX)).toSet()
            else -> error("invalid legacy enqueue receipts")
        }
        val markerPrefix = "flutter.crawl_legacy_enqueue_uncertain."
        val db = writableDatabase
        db.execSQL("CREATE TEMP TABLE IF NOT EXISTS legacy_uncertain (event_key TEXT PRIMARY KEY)")
        db.beginTransaction()
        try {
            db.delete("legacy_uncertain", null, null)
            all.keys.filter { it.startsWith(markerPrefix) }.forEach { marker ->
                val key = marker.removePrefix(markerPrefix)
                if (key !in sent) db.insertOrThrow("legacy_uncertain", null, ContentValues().apply { put("event_key", "flutter.$key") })
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    @Synchronized fun hasPending(prefs: SharedPreferences, prefix: String): Boolean {
        if (prefix == PrefsInbox.ENQUEUE) refreshUncertain(prefs)
        return readableDatabase.rawQuery("SELECT 1 FROM events WHERE prefix=? AND scope=? AND terminal=0${retryableFilter(prefix)} LIMIT 1", arrayOf(prefix, scope(prefs, prefix))).use { it.moveToFirst() }
    }

    @Synchronized fun hasUncertain(prefs: SharedPreferences): Boolean = uncertainKeys(prefs).isNotEmpty()

    /** Event identities, not report numbers/counts: a new request for the same report is a new uncertainty. */
    @Synchronized fun uncertainKeys(prefs: SharedPreferences): Set<String> {
        refreshUncertain(prefs)
        return readableDatabase.rawQuery("SELECT event_key FROM events WHERE prefix=? AND scope=? AND terminal=0 AND event_key IN (SELECT event_key FROM legacy_uncertain)", arrayOf(PrefsInbox.ENQUEUE, scope(prefs, PrefsInbox.ENQUEUE))).use { cursor ->
            buildSet { while (cursor.moveToNext()) add(cursor.getString(0)) }
        }
    }

    @Synchronized fun release(owner: String) {
        writableDatabase.execSQL("UPDATE events SET claim_owner=NULL, claim_until=0 WHERE terminal=0 AND claim_owner=?", arrayOf(owner))
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
        if (prefix == PrefsInbox.ENQUEUE) refreshUncertain(prefs)
        val currentScope = scope(prefs, prefix)
        val pending = mutableListOf<Map<String, String>>()
        val db = writableDatabase
        val now = System.currentTimeMillis()
        db.beginTransaction()
        try {
            db.query("events", arrayOf("event_key", "value"), "prefix=? AND terminal=0 AND scope=?${retryableFilter(prefix)} AND (claim_owner IS NULL OR claim_owner=? OR claim_until<=?)", arrayOf(prefix, currentScope, owner, now.toString()), null, null, "seq", "200").use { c ->
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
