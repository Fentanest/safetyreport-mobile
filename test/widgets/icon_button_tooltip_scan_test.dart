// SQ-U20: 아이콘만 있는 버튼은 스크린리더가 읽을 이름(tooltip)이 있어야 한다.
// lib/ 의 모든 `IconButton(`·`IconButton.filled(` 등 생성 호출을 훑어, 같은 괄호 깊이에 `tooltip:` 이 없으면 실패한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

/// 인자 목록의 최상위(깊이 0)에 [name] 인자가 있는지.
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
  test('every IconButton in lib/ has a tooltip', () {
    final call = RegExp(r'\bIconButton(\.(filled|filledTonal|outlined))?\(');
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final m in call.allMatches(source)) {
        final body = _callBody(source, m.end);
        if (!_hasTopLevelArg(body, 'tooltip')) {
          final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
          missing.add('${file.path}:$line');
        }
      }
    }
    expect(missing, isEmpty, reason: '툴팁 없는 IconButton');
  });
}
