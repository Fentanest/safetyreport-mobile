import '../models/report.dart';

// ── 상수 ─────────────────────────────────────────────────────────────────────

const _cNowStatus = {
  0: '진행', 10: '답변완료', 11: '일부수용', 12: '검토중',
  14: '불수용', 15: '기타', 20: '취하', 30: '이송',
};

const _rejectKeywords = ['부득이하게', '종결합니다', '처벌이 어려운 점', '처분이 불가'];
const _warningKeywords = [
  '교통질서 안내장', '훈방권', '증거에 의해서만', '12대 중과실',
  '82도117', '관리대상으로', '12개 중과실',
];
const _parkingEntries = ['불법주정차신고', '버스전용차로 위반', '쓰레기, 폐기물'];
const _trafficEntry = '자동차·교통위반';

// ── 카테고리 분류 ─────────────────────────────────────────────────────────────

String categoryFromEntryValue(String entryValue) {
  if (entryValue.contains('교통위반')) return 'traffic';
  for (final p in _parkingEntries) {
    if (entryValue.contains(p)) return 'parking';
  }
  return 'other';
}

// ── 전각 숫자 → 반각 변환 ────────────────────────────────────────────────────

String _normalizeNumbers(String s) => s
    .replaceAll('０', '0').replaceAll('１', '1').replaceAll('２', '2')
    .replaceAll('３', '3').replaceAll('４', '4').replaceAll('５', '5')
    .replaceAll('６', '6').replaceAll('７', '7').replaceAll('８', '8')
    .replaceAll('９', '9').replaceAll('，', ',');

// ── 과태료/범칙금 → 원 단위 정수 추출 ────────────────────────────────────────

int extractFineAmount(String fineInfo) {
  final m = RegExp(r'([\d,]+)원').firstMatch(fineInfo);
  if (m == null) return 0;
  return int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
}

// ── parse_json_details 이식 ──────────────────────────────────────────────────

/// 안전신문고 상세 API 응답 JSON을 Report 객체로 파싱.
/// [cNo]: 안전신문고 C_NO (내부 ID)
/// [listData]: 목록 API 항목 (STTEMNT_NO, C_A_TITLE, C_DATE, STSFDG_SCORE)
/// [detailData]: 상세 API 응답 전체
Report parseJsonToReport(Map<String, dynamic> listData, Map<String, dynamic> detailData) {
  final cNo = detailData['C_NO']?.toString() ?? listData['C_NO']?.toString() ?? '';

  // ── 신고 내용 텍스트 파싱 ────────────────────────────────────────────────
  final rawContent = (detailData['C_A_CONTENTS'] ?? detailData['C_A_BODY'] ?? '') as String;
  final content = _normalizeNumbers(rawContent);

  final entryMatch = RegExp(
    r'본 신고는 안전신문고 (?:앱의|포털의) (.+?) 메뉴로 접수된 신고입니다',
  ).firstMatch(content);
  final entryValue = entryMatch?.group(1)?.trim() ??
      (detailData['C_APP_GUBUN_NM'] as String? ?? '');

  final carMatch = RegExp(r'차량번호\s*:\s*(.*?)(?=\n|\(위)').firstMatch(content);
  final carNumber = carMatch != null
      ? carMatch.group(1)!.replaceAll(RegExp(r'\s+'), '')
      : '';

  final dateMatch = RegExp(r'발생일자\s*:\s*(\d{4}[.]\d{1,2}[.]\d{1,2})').firstMatch(content);
  var occurrenceDate = dateMatch?.group(1)?.trim().replaceAll('.', '-') ?? '';

  final timeMatch = RegExp(r'발생시각\s*:\s*(\d{2}:\d{2})').firstMatch(content);
  var occurrenceTime = timeMatch?.group(1)?.trim() ?? '';

  // 위반장소
  var violationLocation = (detailData['RN_ADRES'] as String? ??
      detailData['C_A_ADD2'] as String? ??
      '${detailData['C_A_ADDR_HEAD'] ?? ''} ${detailData['C_A_ADDR_TAIL'] ?? ''}').trim();

  // 보완 완료 시 신고 정보 갱신
  if ((detailData['SPLMNT_CMPTN_DT'] != null) &&
      (detailData['SPLMNT_CMPTN_YN'] as String?) != 'N') {
    if (detailData['SPLMNT_VHRNO'] != null) {
      carNumber == (detailData['SPLMNT_VHRNO'] as String).replaceAll(RegExp(r'\s+'), '');
    }
    final rawDate = (detailData['SPLMNT_DEVEL_DATE'] ?? '').toString();
    if (rawDate.length == 8) {
      occurrenceDate =
          '${rawDate.substring(0, 4)}-${rawDate.substring(4, 6)}-${rawDate.substring(6, 8)}';
    }
    final rawTime = (detailData['SPLMNT_DEVEL_TIME'] ?? '').toString();
    if (rawTime.length >= 4) {
      occurrenceTime = '${rawTime.substring(0, 2)}:${rawTime.substring(2, 4)}';
    }
    final splmntLoc =
        ((detailData['SPLMNT_RN_ADRES'] ?? detailData['SPLMNT_C_A_ADD2'] ?? '') as String)
            .trim();
    if (splmntLoc.isNotEmpty) violationLocation = splmntLoc;
  }

  // ── 신고 상태 (C_NOW) ────────────────────────────────────────────────────
  int cNow = 0;
  try {
    cNow = (detailData['C_NOW'] as num?)?.toInt() ??
        int.tryParse(detailData['C_NOW']?.toString() ?? '') ?? 0;
  } catch (_) {}
  final processStatus = _cNowStatus[cNow] ?? (cNow > 0 ? cNow.toString() : '진행');

  // ── 신고 내용 (차량번호 이전 텍스트) ────────────────────────────────────
  final reportContent = content.split(RegExp(r'\*\s*차량번호')).first.trim();

  // ── 처리 기관 답변 파싱 ──────────────────────────────────────────────────
  var processingStatus = '';
  var processingAgency = '';
  var personInCharge = '';
  var responseDate = '';
  var processingContent = '';
  var processingFinish = 'N';

  final answers = detailData['answers'] as List? ?? [];
  if (answers.isNotEmpty) {
    final latest = answers.last as Map<String, dynamic>;
    processingStatus = latest['C_MANAGER_TYPE_NM'] as String? ?? '';
    if (processingStatus.isEmpty || processingStatus == '진행' || processingStatus == '처리중') {
      processingStatus = latest['C_R_PROC_STAT_NM'] as String? ?? processingStatus;
    }
    if ((processingStatus.isEmpty || processingStatus == '진행' || processingStatus == '처리중') &&
        ['답변완료', '수용', '불수용', '일부수용', '기타'].contains(processStatus)) {
      processingStatus = processStatus;
    }
    if (['수용', '불수용', '일부수용', '기타', '검토중', '답변완료'].contains(processingStatus)) {
      processingFinish = 'Y';
    }
    processingAgency = (latest['C_MANAGE_ORG_NAME'] ?? latest['C_MANAGER_TYPE_NM'] ?? '') as String;
    personInCharge = (latest['C_MANAGE_MAN'] ?? latest['C_R_MOD_ID'] ?? '') as String;
    final rd = (latest['C_DATE'] ?? latest['C_R_MOD_DATE'] ?? '') as String;
    responseDate = rd.length >= 10 ? rd.substring(0, 10) : rd;
    processingContent = (latest['C_MANAGE_CONTENTS'] ?? latest['C_R_BODY'] ?? '') as String;
    processingContent = processingContent
        .replaceAll(RegExp(r'<[^>]+>'), '\n')
        .trim();
    processingContent = _normalizeNumbers(processingContent);
  }

  // 위반법규
  var violationLaw = '';
  final lawMatch = RegExp(r'도로교통법\s*제\d+조(?:\s*제?\d{1,2}항)?').firstMatch(processingContent);
  if (lawMatch != null) {
    violationLaw = lawMatch.group(0)!.replaceAll(RegExp(r'\s+'), '').replaceAll('법제', '법 제');
  }

  // 과태료/범칙금
  var fineEntry = '';
  if (_parkingEntries.any((e) => entryValue.contains(e)) && processingStatus == '수용') {
    fineEntry = '과태료';
  }

  var penaltyAmount = '';
  var penaltyPoints = '';
  final penaltyMatch = RegExp(r'범칙금\s*([\d,]+)\s*원[,\s]*벌점\s*(\d{0,4})\s*점')
      .firstMatch(processingContent);
  final fineMatch = RegExp(r'과태료\s*([\d,]+)\s*원').firstMatch(processingContent);

  if (penaltyMatch != null) {
    penaltyAmount = '범칙금: ${penaltyMatch.group(1)}원';
    penaltyPoints = '벌점: ${penaltyMatch.group(2)}점';
  } else if (fineMatch != null) {
    penaltyAmount = '과태료: ${fineMatch.group(1)}원';
  } else {
    penaltyAmount = fineEntry;
  }

  // 불수용 교정 및 경고 처리
  if (!['수용', '일부수용'].contains(processingStatus) &&
      _rejectKeywords.any((kw) => processingContent.contains(kw))) {
    processingStatus = '불수용';
    processingFinish = 'Y';
    penaltyAmount = '';
    penaltyPoints = '';
  } else if (penaltyAmount.isEmpty &&
      _warningKeywords.any((kw) => processingContent.contains(kw))) {
    penaltyAmount = '경고';
  } else if (penaltyAmount.isEmpty &&
      entryValue.contains(_trafficEntry) &&
      ['수용', '일부수용', '기타'].contains(processingStatus)) {
    penaltyAmount = '미확인';
  }

  // 취하 처리
  if (processStatus == '취하') {
    processingFinish = 'Y';
    processingStatus = '취하';
    penaltyAmount = '';
    penaltyPoints = '';
  }

  if (processingStatus.isEmpty) processingStatus = '처리중';

  // ── 첨부파일 ─────────────────────────────────────────────────────────────
  var mapImage = '';
  final stmntImg = detailData['STTEMNT_IMAGE_URL'] as String? ?? '';
  if (stmntImg.isNotEmpty) {
    mapImage =
        stmntImg.startsWith('/') ? 'https://www.safetyreport.go.kr$stmntImg' : stmntImg;
  }

  final imgLinks = <String>[];
  final otherLinks = <String>[];
  final files = (detailData['ARR_C_FILES'] ?? detailData['files'] ?? []) as List;

  for (final f in files.cast<Map<String, dynamic>>()) {
    var fileUrl = f['FILE_URL'] as String? ?? '';
    if (fileUrl.isEmpty) {
      final atchId = f['ATCH_FILE_ID'];
      fileUrl = atchId != null
          ? 'https://www.safetyreport.go.kr/fileDown/singo/$atchId'
          : '';
    }
    if (fileUrl.isEmpty) continue;
    if (fileUrl.startsWith('/')) fileUrl = 'https://www.safetyreport.go.kr$fileUrl';

    if (fileUrl.contains('MAPIMG')) {
      if (mapImage.isEmpty) mapImage = fileUrl;
      continue;
    }
    if (mapImage.isNotEmpty && fileUrl == mapImage) continue;

    final fileTy = (f['FILE_TY'] ?? '').toString();
    final origNm = (f['ORGINL_FILE_NM'] ?? '').toString().toLowerCase();
    final ext = origNm.isNotEmpty
        ? origNm.split('.').last
        : (f['FILE_EXTSN'] ?? f['EXT'] ?? '').toString().toLowerCase();

    if (['1', '3', '8'].contains(fileTy) ||
        ['jpg', 'jpeg', 'png', 'gif', 'bmp'].contains(ext)) {
      imgLinks.add(fileUrl);
    } else {
      otherLinks.add(fileUrl);
    }
  }

  // ── 제목/신고번호 ─────────────────────────────────────────────────────────
  final titleRaw = (detailData['C_A_TITLE'] ?? listData['C_A_TITLE'] ?? '') as String;
  final name = titleRaw.contains(')') ? titleRaw.split(')').sublist(1).join(')').trim() : titleRaw.trim();
  final reportNumber = (detailData['STTEMNT_NO'] ?? listData['STTEMNT_NO'] ?? '') as String;
  final dateRaw = (detailData['C_DATE'] ?? listData['C_DATE'] ?? '') as String;
  final date = dateRaw.isNotEmpty ? dateRaw.split(' ').first : '';

  // 만족도조사
  final stsfdg = int.tryParse((listData['STSFDG_SCORE'] ?? '0').toString()) ?? 0;

  return Report(
    id: cNo,
    reportNumber: reportNumber,
    name: name,
    date: date,
    responseDate: responseDate,
    agency: processingAgency,
    manager: personInCharge,
    status: processingStatus,
    result: processStatus,
    fineInfo: penaltyAmount,
    penaltyPoints: penaltyPoints,
    carNumber: carNumber,
    law: violationLaw,
    location: violationLocation,
    occurrenceDate: occurrenceDate,
    occurrenceTime: occurrenceTime,
    reportContent: reportContent,
    processContent: processingContent,
    attachedPhotos: imgLinks.join('\n'),
    attachedFiles: otherLinks.join('\n'),
    mapImage: mapImage,
  );
}
