package com.fentanest.mysafetyreport

import org.junit.Assert.*
import org.junit.Test

class CrawlOutcomeTest {
    @Test fun failureCancellationPartialAndUnknownAreNotSuccessfulCompletion() {
        for (state in listOf("failed", "cancelled", "partial", "unknown", "future-state")) {
            assertFalse(CrawlOutcome.title(state).startsWith("✅"))
            assertFalse(CrawlOutcome.body(state, 0).contains("변경사항이 없습니다"))
        }
        assertTrue(CrawlOutcome.title("cancelled").contains("취소"))
        assertTrue(CrawlOutcome.title("partial").contains("일부"))
        assertTrue(CrawlOutcome.title("failed").contains("실패"))
    }
    @Test fun successfulAndLegacyCompletionKeepExistingCountMeaning() {
        for (state in listOf("", "succeeded")) {
            assertEquals("✅ 크롤링 완료", CrawlOutcome.title(state))
            assertTrue(CrawlOutcome.body(state, 7).contains("7건"))
            assertTrue(CrawlOutcome.body(state, 0).contains("변경사항이 없습니다"))
        }
    }
}
