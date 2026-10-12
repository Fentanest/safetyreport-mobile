package com.fentanest.mysafetyreport

object NotificationReports {
    fun accepts(packageName: String) = packageName in setOf("kr.go.safepeople", "com.kakao.talk")
    // Match all expanded/inbox fields, without accepting a truncated longer number.
    fun extract(parts: List<String?>): Set<String> = Regex("(?<![A-Za-z0-9])SPP-\\d{4}-\\d{6,8}(?![0-9])")
        .findAll(parts.filterNotNull().joinToString(" ")).map { it.value }.toSet()
}
