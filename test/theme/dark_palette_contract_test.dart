// 다크 B안 팔레트 — 서버 웹 tokens.css 와 같은 값(contracts/dark-palette.json, 두 레포 바이트 동일).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/theme/app_theme.dart';
import 'package:safetyreport/theme/sr_colors.dart';

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  final p =
      jsonDecode(File('contracts/dark-palette.json').readAsStringSync())
          as Map<String, dynamic>;

  test('SrColors.dark and AppTheme dark roles use the shared palette', () {
    final t = SrColors.dark;
    final scheme = AppTheme.dark().colorScheme;
    expect(_hex(t.background), p['bg']);
    expect(_hex(t.surface), p['surface']);
    expect(_hex(t.surfaceAlt), p['surface_2']);
    expect(_hex(scheme.surfaceContainerHigh), p['surface_3']);
    expect(_hex(t.border), p['border']);
    expect(_hex(t.textPrimary), p['text']);
    expect(_hex(t.textSecondary), p['text_muted']);
    expect(_hex(t.brand), p['primary_fill']);
    expect(_hex(AppTheme.darkPrimaryFill), p['primary_fill']);
    expect(_hex(scheme.primary), p['primary_text']);
  });
}
