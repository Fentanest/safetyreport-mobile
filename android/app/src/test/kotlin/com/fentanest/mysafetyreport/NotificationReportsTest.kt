package com.fentanest.mysafetyreport

import org.junit.Assert.*
import org.junit.Test

class NotificationReportsTest {
    @Test fun expandedAndGroupedTextIsReadAndDeduplicated() {
        assertEquals(setOf("SPP-2610-1234567", "SPP-2610-7654321"), NotificationReports.extract(listOf(
            "안전신문고", "답변 도착", "답변 SPP-2610-1234567", "SPP-2610-1234567\nSPP-2610-7654321")))
    }
    @Test fun truncatedLongNumberDoesNotBecomeAnotherReport() {
        assertTrue(NotificationReports.extract(listOf(null, "SPP-2610-123456789", "SPP-2610-12345")).isEmpty())
    }
    @Test fun onlyKnownSenderPackagesAreAccepted() {
        assertTrue(NotificationReports.accepts("kr.go.safepeople"))
        assertTrue(NotificationReports.accepts("com.kakao.talk"))
        assertFalse(NotificationReports.accepts("com.fentanest.mysafetyreport"))
        assertFalse(NotificationReports.accepts("unknown.package"))
    }
}
