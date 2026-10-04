package com.fentanest.mysafetyreport

/** 종료 사실과 성공을 구별한다. outcome 없는 구서버만 기존 완료 의미를 쓴다. */
object CrawlOutcome {
    fun title(outcome: String): String = when (outcome) {
        "", "succeeded" -> "✅ 크롤링 완료"
        "partial" -> "⚠️ 크롤링 일부 완료"
        "failed" -> "⚠️ 크롤링 실패"
        "cancelled" -> "⏹️ 크롤링 취소"
        else -> "⚠️ 크롤링 결과 확인 필요"
    }

    fun body(outcome: String, count: Int): String = when (outcome) {
        "", "succeeded" -> if (count > 0) "크롤링이 완료되었습니다. ${count}건의 변경사항이 있습니다." else "크롤링이 완료되었습니다. 변경사항이 없습니다."
        "partial" -> "일부 자료만 수집되었습니다. 서버의 크롤링 현황을 확인하세요. 변경 ${count}건."
        "failed" -> "크롤링에 실패했습니다. 서버의 크롤링 현황을 확인하세요."
        "cancelled" -> "크롤링이 취소되었습니다."
        else -> "크롤링 종료 결과를 확인할 수 없습니다. 서버의 크롤링 현황을 확인하세요."
    }
}
