package com.fentanest.mysafetyreport

import android.app.Application
import android.content.Context
import io.flutter.plugins.sharedpreferences.JSON_LIST_PREFIX
import io.flutter.plugins.sharedpreferences.LIST_PREFIX
import io.flutter.plugins.sharedpreferences.ListEncoder
import org.json.JSONArray
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class, sdk = [28])
class ProcessingInboxStoreTest {
    private lateinit var store: ProcessingInboxStore
    private val prefs get() = RuntimeEnvironment.getApplication().getSharedPreferences("fixture", Context.MODE_PRIVATE)
    private val prefix = PrefsInbox.ENQUEUE
    private val a = "SPP-2610-1234567"
    private val b = "SPP-2610-7654321"
    @Before fun setup() {
        val context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("processing_inbox.db")
        val constructor = ProcessingInboxStore::class.java.getDeclaredConstructor(Context::class.java)
        constructor.isAccessible = true
        store = constructor.newInstance(context)
        prefs.edit().clear().commit()
    }
    @After fun close() { store.close() }
    @Suppress("UNCHECKED_CAST")
    private fun read(owner: String = "worker") = store.read(prefs, prefix, emptyList(), owner)["pending"] as List<Map<String, String>>
    private fun post(text: String) {
        for (number in NotificationReports.extract(listOf(text))) {
            store.putNotification(prefs, prefix, number, packageName = "kr.go.safepeople")
        }
    }
    private fun count() = store.readableDatabase.rawQuery("SELECT COUNT(*) FROM events", null).use { it.moveToFirst(); it.getInt(0) }

    @Test fun legacyUncertainRequestsDoNotWakeWorkerOrStarveNewWork() {
        repeat(205) { store.put(prefix, a, scope = store.scope(prefs, prefix)) }
        assertFalse("uncertain legacy work must not trigger authentication/retry", store.hasPending(prefs, prefix))
        post(a)
        assertTrue(store.hasPending(prefs, prefix))
        val batch = read()
        assertEquals(1, batch.size)
        assertTrue(batch.single().getValue("key").startsWith("inbox.enqueue.native.notification."))
        store.acknowledge(batch.map { "flutter." + it.getValue("key") }, "worker")
        assertFalse(store.hasPending(prefs, prefix))
        assertEquals(206, count())
        store.readableDatabase.rawQuery("SELECT COUNT(*) FROM events WHERE terminal=0 AND claim_owner IS NULL", null).use {
            assertTrue(it.moveToFirst())
            assertEquals(205, it.getInt(0))
        }
    }

    @Test fun uncertainNotificationBoundaryDoesNotClaimOrRetryButPreservesAllRows() {
        val keys = (0 until 200).map { prefix + "native.notification.fixture-$it" }
        keys.forEach { key ->
            store.put(prefix, a, key, store.scope(prefs, prefix))
            prefs.edit().putBoolean("flutter.crawl_legacy_enqueue_uncertain." + key.removePrefix("flutter."), true).commit()
        }
        // Simulate process restart: no in-memory Dart claim/filter remains.
        store.close()
        val constructor = ProcessingInboxStore::class.java.getDeclaredConstructor(Context::class.java)
        constructor.isAccessible = true
        store = constructor.newInstance(RuntimeEnvironment.getApplication())
        assertFalse(store.hasPending(prefs, prefix))
        assertTrue(store.hasUncertain(prefs))
        val fresh = store.put(prefix, b, prefix + "native.notification.fresh", store.scope(prefs, prefix))
        assertTrue(store.hasPending(prefs, prefix))
        assertEquals(listOf(b), read().map { it["value"] })
        store.acknowledge(listOf(fresh), "worker")
        repeat(3) {
            assertFalse(store.hasPending(prefs, prefix))
            assertTrue(read().isEmpty())
        }
        assertEquals(201, count())
        store.readableDatabase.rawQuery("SELECT COUNT(*) FROM events WHERE terminal=0 AND claim_owner IS NULL", null).use {
            assertTrue(it.moveToFirst())
            assertEquals(200, it.getInt(0))
        }
        assertTrue(keys.all { prefs.contains("flutter.crawl_legacy_enqueue_uncertain." + it.removePrefix("flutter.")) })
    }

    @Test fun confirmedLegacyReceiptRemainsAckableAcrossBothPreferenceEncodings() {
        val key = store.put(prefix, a, prefix + "native.notification.confirmed", store.scope(prefs, prefix))
        val dartKey = key.removePrefix("flutter.")
        prefs.edit().putBoolean("flutter.crawl_legacy_enqueue_uncertain.$dartKey", true).commit()
        for (encoded in listOf(
            JSON_LIST_PREFIX + JSONArray(listOf(dartKey)).toString(),
            LIST_PREFIX + ListEncoder().encode(arrayListOf(dartKey))
        )) {
            prefs.edit().putString("flutter.crawl_legacy_enqueue_sent_keys", encoded).commit()
            assertTrue(store.hasPending(prefs, prefix))
            assertFalse(store.hasUncertain(prefs))
            assertEquals(listOf(a), read().map { it["value"] })
        }
        store.acknowledge(listOf(key), "worker")
        assertFalse(store.hasPending(prefs, prefix))
        assertEquals(1, count())
    }

    @Test fun uncertainRowDoesNotCoalesceNewNotificationForSameReport() {
        val key = store.put(prefix, a, prefix + "native.notification.uncertain", store.scope(prefs, prefix))
        prefs.edit().putBoolean("flutter.crawl_legacy_enqueue_uncertain." + key.removePrefix("flutter."), true).commit()
        post(a)
        assertEquals(2, count())
        assertEquals(listOf(a), read().map { it["value"] })
        assertNotEquals(key.removePrefix("flutter."), read().single()["key"])
    }

    @Test fun actionableBatchStillHonorsLimitAndUncertainNoticeHonorsScope() {
        repeat(201) { store.put(prefix, a, prefix + "native.notification.$it", store.scope(prefs, prefix)) }
        assertEquals(200, read().size)
        val key = prefix + "native.notification.0"
        prefs.edit().putBoolean("flutter.crawl_legacy_enqueue_uncertain." + key.removePrefix("flutter."), true).commit()
        assertTrue(store.hasUncertain(prefs))
        prefs.edit().putString("flutter.baseUrl", "https://other.invalid").commit()
        assertFalse(store.hasUncertain(prefs))
        assertFalse(store.hasPending(prefs, prefix))
        assertTrue(read().isEmpty())
        assertEquals(201, count())
    }

    @Test fun differentScopeIsPreservedAndBecomesReadableOnlyWhenOriginalScopeReturns() {
        post(a) // Notification received before server configuration.
        prefs.edit().putString("flutter.baseUrl", "https://fixture.invalid").commit()
        post(b)
        val batch = read()
        assertEquals(listOf(b), batch.map { it["value"] })
        assertEquals(1, store.read(prefs, prefix, emptyList(), "worker")["blockedScope"])
        store.acknowledge(batch.map { "flutter." + it.getValue("key") }, "worker")
        assertFalse(store.hasPending(prefs, prefix))
        assertEquals(2, count())
        prefs.edit().remove("flutter.baseUrl").commit()
        assertEquals(listOf(a), read().map { it["value"] })
    }

    @Test fun summaryGrowthDoesNotReenqueueClaimedReport() {
        post("답변 $a")
        read()
        post("답변 $a\n답변 $b")
        assertEquals(2, count())
        assertEquals(setOf(a, b), read().map { it.getValue("value") }.toSet())
    }

    @Test fun summaryGrowthDoesNotReenqueueCompletedReport() {
        post("답변 $a")
        store.acknowledge(read().map { "flutter." + it.getValue("key") }, "worker")
        post("답변 $a\n답변 $b")
        assertEquals(2, count())
        assertEquals(listOf(b), read().map { it["value"] })
    }

    @Test fun standaloneTimestampKeysRemainActionable() {
        val queue = PrefsInbox.QUEUE
        val key = store.put(queue, a, scope = store.scope(prefs, queue))
        assertTrue(store.hasPending(prefs, queue))
        val batch = store.read(prefs, queue, emptyList(), "worker")["pending"] as List<*>
        assertEquals(1, batch.size)
        store.acknowledge(listOf(key), "worker")
        assertFalse(store.hasPending(prefs, queue))
        assertEquals(1, count())
    }

    @Test fun laterNotificationDuringFetchIsPreservedAfterBoundedDedupWindow() {
        post(a)
        read()
        store.writableDatabase.execSQL("UPDATE notification_receipts SET created_at=?", arrayOf(System.currentTimeMillis() - 121_000L))
        post(a)
        assertEquals(2, count())
    }

    @Test fun fingerprintSeparatesSenderAndScope() {
        post(a)
        read()
        store.putNotification(prefs, prefix, a, packageName = "com.kakao.talk")
        assertEquals(2, count())
        prefs.edit().putString("flutter.baseUrl", "https://fixture.invalid").commit()
        post(a)
        assertEquals(3, count())
        assertEquals(1, read().size)
    }
}
