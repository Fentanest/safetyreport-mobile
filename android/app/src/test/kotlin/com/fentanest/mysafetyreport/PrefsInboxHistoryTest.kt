package com.fentanest.mysafetyreport

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class PrefsInboxHistoryTest {
    /** Android commits mutate memory before returning a disk failure. */
    private class Preferences(initial: Map<String, Any>, failures: List<Boolean> = emptyList()) {
        val memory = LinkedHashMap(initial)
        val disk = LinkedHashMap(initial)
        val outcomes = ArrayDeque(failures)
        val writes = mutableListOf<Map<String, Any>>()
        val prefs = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)) { _, method, _ ->
            when (method.name) {
                "getAll" -> LinkedHashMap(memory)
                "edit" -> editor()
                else -> error("unexpected preferences call ${method.name}")
            }
        } as SharedPreferences

        private fun editor(): SharedPreferences.Editor {
            val updates = LinkedHashMap<String, Any?>()
            lateinit var proxy: SharedPreferences.Editor
            proxy = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
                arrayOf(SharedPreferences.Editor::class.java)) { _, method, args ->
                when (method.name) {
                    "putString", "putLong" -> { updates[args!![0] as String] = args[1]; proxy }
                    "remove" -> { updates[args!![0] as String] = null; proxy }
                    "commit" -> {
                        updates.forEach { (key, value) -> if (value == null) memory.remove(key) else memory[key] = value }
                        writes.add(LinkedHashMap(memory))
                        val success = if (outcomes.isEmpty()) true else outcomes.removeFirst()
                        if (success) { disk.clear(); disk.putAll(memory) }
                        success
                    }
                    else -> error("unexpected editor call ${method.name}")
                }
            } as SharedPreferences.Editor
            return proxy
        }
    }

    @Test fun successfulHistoryAndCursorUseOneCommit() {
        val p = Preferences(mapOf("cursor" to 7L))
        PrefsInbox.writeHistory(p.prefs, PrefsInbox.HISTORY, "event8", "cursor" to 8L)
        assertEquals(1, p.writes.size)
        assertEquals(8L, p.disk["cursor"])
        assertEquals(listOf("event8"), p.disk.filterKeys { it.startsWith(PrefsInbox.HISTORY) }.values.toList())
        assertEquals(p.disk, p.memory)
    }

    @Test fun failedCommitRestoresMemoryCursorAndHistoryBeforeReplay() {
        val old = mapOf<String, Any>("cursor" to 7L, "unrelated" to "keep")
        val p = Preferences(old, listOf(false, true))
        assertThrows(IllegalStateException::class.java) {
            PrefsInbox.writeHistory(p.prefs, PrefsInbox.HISTORY, "failedEvent8", "cursor" to 8L)
        }
        assertEquals(old, p.memory)
        assertEquals(old, p.disk)
        PrefsInbox.writeHistory(p.prefs, PrefsInbox.HISTORY, "replayedEvent8", "cursor" to 8L)
        assertEquals(8L, p.disk["cursor"])
        assertEquals(listOf("replayedEvent8"), p.disk.filterKeys { it.startsWith(PrefsInbox.HISTORY) }.values.toList())
    }

    @Test fun failedCommitAndFailedRollbackPreserveTrimmedHistoryAndAbsentCursor() {
        val old = (1..200).associate { PrefsInbox.HISTORY + it.toString().padStart(15, '0') to "old$it" }
        val p = Preferences(old, listOf(false, false))
        assertThrows(IllegalStateException::class.java) {
            PrefsInbox.writeHistory(p.prefs, PrefsInbox.HISTORY, "event1", "cursor" to 1L)
        }
        assertEquals(old, p.memory)
        assertEquals(old, p.disk)
        assertFalse(p.memory.containsKey("cursor"))
        assertEquals(2, p.writes.size)
    }
}
