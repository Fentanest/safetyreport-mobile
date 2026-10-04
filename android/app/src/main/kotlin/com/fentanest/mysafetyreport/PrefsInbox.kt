package com.fentanest.mysafetyreport

import android.content.SharedPreferences
import android.content.Context
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/**
 * 앱(Flutter)으로 넘기는 설정 수신함 (저장 계층 재설계 R6, M-29/M-31).
 *
 * 앱과 같은 설정 키를 읽고-고쳐-쓰면 거의 동시에 쓸 때 한쪽이 사라진다. 서비스는 매번 고유한 새 키에만 쓰고,
 * 합치기·지우기는 앱(lib/services/prefs_inbox.dart)이 한다. 접두어는 Dart 쪽과 같아야 한다("flutter." 는 플러그인 접두어).
 */
object PrefsInbox {
    const val HISTORY = "flutter.inbox.history."
    const val PENDING = "flutter.inbox.pending."
    const val ENQUEUE = "flutter.inbox.enqueue."
    const val QUEUE = "flutter.inbox.queue."
    private const val MAX_KEYS = 200
    private val seq = AtomicInteger(0)

    /** [prefix] 아래 새 키에 [value] 를 쓴다. 앱이 오래 안 열리면 오래된 것부터 [MAX_KEYS] 개로 자른다. */
    fun put(context: Context, prefs: SharedPreferences, prefix: String, value: String,
            terminalCursor: Pair<String, Long>? = null) {
        if (prefix == QUEUE || prefix == PENDING) {
            ProcessingInboxStore.get(context).let { it.put(prefix, value, scope = it.scope(prefs, prefix)) }
            return
        }
        writeHistory(prefs, prefix, value, terminalCursor)
    }

    @Synchronized
    internal fun writeHistory(prefs: SharedPreferences, prefix: String, value: String,
                              terminalCursor: Pair<String, Long>? = null) {
        val key = prefix + System.currentTimeMillis().toString().padStart(15, '0') +
            "_" + seq.incrementAndGet().toString().padStart(6, '0') + "_" + UUID.randomUUID()
        val before = prefs.all
        val keys = before.keys.filter { it.startsWith(prefix) }.sorted()
        val removed = if (prefix == HISTORY && keys.size >= MAX_KEYS) keys.take(keys.size - MAX_KEYS + 1) else emptyList()
        val editor = prefs.edit().putString(key, value)
        terminalCursor?.let { editor.putLong(it.first, it.second) }
        removed.forEach { editor.remove(it) }
        if (!editor.commit()) {
            // SharedPreferences updates memory even when its disk commit fails.
            // Restore only our changes so reconnect cannot skip the unsaved event.
            val rollback = prefs.edit().remove(key)
            removed.forEach { oldKey -> rollback.putString(oldKey, before[oldKey] as String) }
            terminalCursor?.let { (cursorKey, _) ->
                if (before.containsKey(cursorKey)) rollback.putLong(cursorKey, before[cursorKey] as Long)
                else rollback.remove(cursorKey)
            }
            rollback.commit()
            error("inbox history persistence failed")
        }
    }
}
