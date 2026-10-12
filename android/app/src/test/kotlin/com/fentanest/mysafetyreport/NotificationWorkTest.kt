package com.fentanest.mysafetyreport

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.os.Looper
import androidx.work.*
import androidx.work.impl.utils.taskexecutor.WorkManagerTaskExecutor
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import kotlin.coroutines.EmptyCoroutineContext
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, application = Application::class, sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class NotificationWorkTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val prefs get() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val notices get() = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private lateinit var store: ProcessingInboxStore

    @Before fun setup() {
        resetStore()
        context.deleteDatabase("processing_inbox.db")
        prefs.edit().clear().commit()
        context.getSharedPreferences("NotificationWork", Context.MODE_PRIVATE).edit().clear().commit()
        store = ProcessingInboxStore.get(context)
    }

    @After fun cleanup() { resetStore() }

    private fun resetStore() {
        ProcessingInboxStore::class.java.getDeclaredField("instance").apply {
            isAccessible = true
            (get(null) as? ProcessingInboxStore)?.close()
            set(null, null)
        }
    }

    private fun uncertain(id: String): String {
        val key = store.put(PrefsInbox.ENQUEUE, "SPP-2610-1234567",
            PrefsInbox.ENQUEUE + "native.notification.$id", store.scope(prefs, PrefsInbox.ENQUEUE))
        prefs.edit().putBoolean("flutter.crawl_legacy_enqueue_uncertain." + key.removePrefix("flutter."), true).commit()
        return key
    }

    private fun resolve(key: String) {
        store.writableDatabase.execSQL("UPDATE events SET terminal=1 WHERE event_key=?", arrayOf(key))
    }

    private fun worker(): NotificationWork {
        val direct = Executor { it.run() }
        return NotificationWork(context, WorkerParameters(UUID.randomUUID(), Data.EMPTY, emptyList(),
            WorkerParameters.RuntimeExtras(), 0, 0, direct, EmptyCoroutineContext,
            WorkManagerTaskExecutor(direct), object : WorkerFactory() {
                override fun createWorker(context: Context, name: String, params: WorkerParameters): ListenableWorker? = null
            }, ProgressUpdater { _, _, _ -> error("unexpected progress") },
            ForegroundUpdater { _, _, _ -> error("unexpected foreground") }))
    }

    private fun set(worker: NotificationWork, name: String, value: Any) {
        NotificationWork::class.java.getDeclaredField(name).apply { isAccessible = true; set(worker, value) }
    }

    private fun drain(worker: NotificationWork) {
        val io = NotificationWork::class.java.getDeclaredField("io").apply { isAccessible = true }.get(worker) as ExecutorService
        val deadline = System.nanoTime() + 5_000_000_000L
        while (!io.isTerminated && System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertTrue("worker completion timed out", io.isTerminated)
    }

    // Complete the real worker after its Dart processing boundary, without starting a Flutter engine.
    private fun finish(success: Boolean = true, admitted: Boolean = true) {
        val worker = worker()
        set(worker, "hadPending", true)
        set(worker, "admitted", admitted)
        set(worker, "stamp", ClientGateGuard.configStamp(prefs))
        NotificationWork::class.java.getDeclaredMethod("finish", Boolean::class.javaPrimitiveType).apply {
            isAccessible = true
            invoke(worker, success)
        }
        drain(worker)
    }

    private fun idleCycle() {
        val worker = worker()
        val future = worker.startWork()
        drain(worker)
        assertEquals(ListenableWorker.Result.success(), future.get())
    }

    private fun assertUncertainNotice() {
        assertEquals(1, notices.activeNotifications.size)
        assertEquals("크롤링 접수 확인 필요", notices.activeNotifications.single().notification.extras.getString("android.title"))
    }

    @Test fun dismissedNoticeDoesNotReturnOnPeriodicIdleRunsAfterRestart() {
        uncertain("a")
        finish()
        assertUncertainNotice()
        notices.cancelAll() // User dismisses the notice.
        resetStore()
        store = ProcessingInboxStore.get(context)
        repeat(3) { idleCycle(); assertTrue(notices.activeNotifications.isEmpty()) }
        assertTrue(store.hasUncertain(prefs))
        assertFalse(store.hasPending(prefs, PrefsInbox.ENQUEUE))
    }

    @Test fun idleWorkerDoesNotPostEvenAnUnseenSet() {
        uncertain("a")
        idleCycle()
        assertTrue(notices.activeNotifications.isEmpty())
        finish() // The idle run must not mark the unseen set as already notified.
        assertUncertainNotice()
    }

    @Test fun sameSetDoesNotReturnAfterOtherWorkSucceedsOrFails() {
        uncertain("a")
        finish()
        assertUncertainNotice()
        notices.cancelAll()
        finish(success = false)
        assertTrue(notices.activeNotifications.isEmpty())
        finish()
        assertTrue(notices.activeNotifications.isEmpty())
    }

    @Test fun newAndReplacedAndShrinkingSetsEachNotifyOnce() {
        val a = uncertain("a")
        finish()
        notices.cancelAll()
        val b = uncertain("b")
        finish(success = false)
        assertUncertainNotice()
        notices.cancelAll()
        resolve(a)
        uncertain("c") // Same count, different event identity.
        finish()
        assertUncertainNotice()
        notices.cancelAll()
        resolve(b)
        finish()
        assertUncertainNotice()
        notices.cancelAll()
        finish()
        assertTrue(notices.activeNotifications.isEmpty())
    }

    @Test fun emptySetAndSuccessfulReceiptResetOnlyThatScope() {
        val a = uncertain("a")
        finish()
        notices.cancelAll()
        prefs.edit().putString("flutter.crawl_legacy_enqueue_sent_keys",
            io.flutter.plugins.sharedpreferences.JSON_LIST_PREFIX + org.json.JSONArray(listOf(a.removePrefix("flutter."))).toString()).commit()
        finish()
        assertEquals("자동 처리 요청 완료", notices.activeNotifications.single().notification.extras.getString("android.title"))
        notices.cancelAll()
        prefs.edit().remove("flutter.crawl_legacy_enqueue_sent_keys").commit()
        finish()
        assertUncertainNotice()
    }

    @Test fun scopeSwitchDoesNotForgetAlreadyNotifiedSet() {
        uncertain("a")
        finish()
        notices.cancelAll()
        prefs.edit().putString("flutter.baseUrl", "https://other.invalid").commit()
        idleCycle()
        uncertain("b")
        finish()
        assertUncertainNotice()
        notices.cancelAll()
        prefs.edit().remove("flutter.baseUrl").commit()
        finish()
        assertTrue(notices.activeNotifications.isEmpty())
    }

    @Test fun unadmittedWorkerDoesNotNotifyOrConsumeReceipt() {
        uncertain("a")
        finish(success = false, admitted = false)
        assertTrue(notices.activeNotifications.isEmpty())
        finish()
        assertUncertainNotice()
    }
}
