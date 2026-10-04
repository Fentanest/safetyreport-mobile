// SQ-U19·SQ-U23: 화면 코드가 디자인 토큰(lib/theme/)을 우회하지 않는지 lib/ 소스를 훑는다.
//
// 일부러 고정한 값은 같은 줄이나 바로 윗줄에 `sr-allow` 주석(이유 포함)을 달면 통과한다.
// 예) 지도 마커 색(지도 타일은 테마와 무관하게 밝다), 차트 막대 끝 반경(막대 폭에 묶인 표식).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 상태·처분 기준색 팔레트(spec §2 D-02). 테마와 무관한 고정값이라 파일 단위로 허용한다.
const _colorLiteralFiles = {'lib/server_palette.dart'};

/// 차트 축 눈금(11)을 쓰는 파일. 그 밖의 곳은 12(Caption) 미만을 쓰지 않는다(spec §3).
const _chartAxisFiles = {'lib/widgets/stats_overview_section.dart'};

/// spec §4 반경 단계 + 알약.
final _radiusSteps = <double>{4, 8, 12, 16, 24, 999};

class _Hit {
  final String path;
  final int line;
  final String text;
  _Hit(this.path, this.line, this.text);
  @override
  String toString() => '$path:$line  ${text.trim()}';
}

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _norm(String path) => path.replaceAll('\\', '/');

bool _isTheme(String path) => _norm(path).startsWith('lib/theme/');

/// [pattern] 이 걸린 줄 중 `sr-allow` 표시가 없는 줄.
List<_Hit> _scan(
  RegExp pattern, {
  bool Function(String path)? skipFile,
  bool Function(RegExpMatch m, String path)? allow,
}) {
  final hits = <_Hit>[];
  for (final file in _dartFiles()) {
    final path = _norm(file.path);
    if (skipFile?.call(path) ?? false) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (final m in pattern.allMatches(line)) {
        final marked =
            line.contains('sr-allow') ||
            (i > 0 && lines[i - 1].contains('sr-allow'));
        if (marked || (allow?.call(m, path) ?? false)) continue;
        hits.add(_Hit(path, i + 1, line));
      }
    }
  }
  return hits;
}

/// [source] 의 [open] 위치(여는 괄호 다음)부터 짝이 맞는 닫는 괄호 앞까지.
String _callBody(String source, int open) {
  var depth = 1;
  var i = open;
  while (depth > 0 && i < source.length) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    i++;
  }
  return source.substring(open, i - 1);
}

bool _hasTopLevelArg(String body, String name) {
  var depth = 0;
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (depth == 0 && body.startsWith('$name:', i)) return true;
  }
  return false;
}

void main() {
  test('StatusTone 이중 호출이 없다 — context.tone(SrTone.x) 를 쓴다', () {
    final hits = <String>[];
    final double = RegExp(r'StatusTone\.of\(\s*StatusTone\.of\(');
    for (final file in _dartFiles()) {
      final source = file.readAsStringSync();
      for (final m in double.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
        hits.add('${_norm(file.path)}:$line');
      }
    }
    expect(hits, isEmpty);
  });

  test('Material 원색(Colors.green 등)을 lib/theme 밖에서 쓰지 않는다', () {
    final hits = _scan(
      RegExp(
        r'\bColors\.(green|orange|amber|red|indigo|blue|teal|deepPurple|purple|'
        r'pink|brown|grey|yellow|lime|cyan|blueGrey|deepOrange|lightBlue|'
        r'lightGreen)\b',
      ),
      skipFile: _isTheme,
    );
    expect(
      hits,
      isEmpty,
      reason: 'SrColors 의미색(context.semantic/tone) 또는 분류색을 쓰세요:\n${hits.join('\n')}',
    );
  });

  test('Color(0x…) 리터럴은 lib/theme 와 고정 팔레트에만 있다', () {
    final hits = _scan(
      RegExp(r'\bColor\(0x[0-9A-Fa-f]{8}\)'),
      skipFile: (p) => _isTheme(p) || _colorLiteralFiles.contains(p),
    );
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('글자 크기 리터럴은 12 이상(차트 축 파일만 11 허용)', () {
    final hits = _scan(
      RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)\b'),
      allow: (m, path) {
        final v = double.parse(m.group(1)!);
        if (v >= 12) return true;
        return v == 11 && _chartAxisFiles.contains(path);
      },
    );
    expect(hits, isEmpty, reason: 'SrFontSize.caption(12) 이상을 쓰세요:\n${hits.join('\n')}');
  });

  test('차트 축 글자(SrFontSize.chartAxis)는 차트 파일에서만 쓴다', () {
    final hits = _scan(
      RegExp(r'SrFontSize\.chartAxis|SrTextStyles\.chartAxis'),
      skipFile: (p) => _isTheme(p) || _chartAxisFiles.contains(p),
    );
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('모서리 반경 리터럴은 spec 단계(4/8/12/16/24/999)만 — 보통은 SrRadius', () {
    final hits = _scan(
      RegExp(r'(?:Radius|BorderRadius)\.circular\(\s*(\d+(?:\.\d+)?)\s*\)'),
      skipFile: _isTheme,
      allow: (m, _) => _radiusSteps.contains(double.parse(m.group(1)!)),
    );
    expect(hits, isEmpty, reason: 'SrRadius 를 쓰세요:\n${hits.join('\n')}');
  });

  test('SnackBar 배경색은 showSrSnack 한 곳에서만 정한다', () {
    final call = RegExp(r'\bSnackBar\(');
    final hits = <String>[];
    for (final file in _dartFiles()) {
      final path = _norm(file.path);
      if (path == 'lib/widgets/sr_snack_bar.dart') continue;
      final source = file.readAsStringSync();
      for (final m in call.allMatches(source)) {
        if (_hasTopLevelArg(_callBody(source, m.end), 'backgroundColor')) {
          final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
          hits.add('$path:$line');
        }
      }
    }
    expect(hits, isEmpty, reason: 'showSrSnack(kind: …) 를 쓰세요');
  });

  test('스캔 자체가 lib/ 를 읽는다(빈 결과로 거짓 통과하지 않음)', () {
    expect(_dartFiles().length, greaterThan(50));
    expect(
      _scan(RegExp(r'SrRadius\.'), skipFile: _isTheme).length,
      greaterThan(50),
    );
  });
}
