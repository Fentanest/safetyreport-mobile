import '../services/law_citations.dart' show decodeLawEntity;

final _explicitLineBreak = RegExp(r'<br\s*/?>', caseSensitive: false);
final _displayEntity = RegExp(
  r'&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);',
);
final _lineEnd = RegExp(r'\r\n|\r|\n');

/// 신고 문자열의 화면 표시를 정리한다. 저장·내보내기 원문에는 적용하지 않는다.
/// 복사 검색은 별도 ReportDisplaySearch에서 표시 문구와 비교할 때만 사용한다.
///
/// 원문에 있던 명확한 br 태그를 먼저 줄바꿈하고 엔터티를 한 번만 복원한다.
/// 복원한 꺾쇠 문구를 다시 태그로 해석하지 않으며 기존 빈 줄·CRLF도 유지한다.
String reportDisplayText(String raw) => raw
    .replaceAll(_explicitLineBreak, '\n')
    .replaceAllMapped(_displayEntity, (m) => decodeLawEntity(m[0]!));

/// 두 줄 목록 제목에서 빈 줄이 미리보기 공간을 차지하지 않도록 한다.
/// 상세 제목과 본문은 [reportDisplayText]로 원래 줄바꿈을 유지한다.
String reportTitlePreview(String raw) => reportDisplayText(
  raw,
).split(_lineEnd).where((line) => line.trim().isNotEmpty).join('\n');
