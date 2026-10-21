import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/widgets/community_upload_panel.dart';
import 'package:safetyreport/widgets/client_notice_host.dart';
import 'package:safetyreport/widgets/community_account_card.dart'
    show communityAuthNavigatorKey;
import 'package:safetyreport/community/client_notice.dart';
import 'package:safetyreport/community/community_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets(
    'raw progress shows available denominator, unavailable and retry',
    (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommunityUploadPanel(
              data: CommunityPanelData(
                clientMode: false,
                rawBackfill: {
                  'state': 'holds',
                  'stats': {
                    'total': 3,
                    'available': 2,
                    'sent': 1,
                    'raw_unavailable': 1,
                    'filled': 2,
                    'unfilled': 1,
                    'holds': 1,
                  },
                },
              ),
              onRetryRaw: () => retried++,
            ),
          ),
        ),
      );
      expect(find.textContaining('원본 전송 1 / 2'), findsOneWidget);
      expect(find.textContaining('원본 없음 1건'), findsOneWidget);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('원본 전송 다시 시도'));
      expect(retried, 1);
    },
  );
  testWidgets('ACK notice is shown globally outside the settings card', (
    tester,
  ) async {
    ClientNotice.current.value = null;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: communityAuthNavigatorKey,
        builder: (context, child) => ClientNoticeHost(child: child!),
        home: const Scaffold(body: Text('신고내역')),
      ),
    );
    ClientNotice.current.value = {
      ...ClientNotice.fallback,
      'message': '합성 전역 업데이트 안내',
    };
    await tester.pumpAndSettle();
    expect(find.text('합성 전역 업데이트 안내'), findsOneWidget);
    expect(find.text('스토어 열기'), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    ClientNotice.current.value = null;
  });
  testWidgets('required notice from the store opens exactly one dialog and is not repeated that day', (
    tester,
  ) async {
    sqfliteFfiInit();
    ClientNotice.current.value = null;
    late Directory tmp;
    late String dbPath;
    late CommunityStore store;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('notice_host');
      dbPath = '${tmp.path}/community.db';
      store = await CommunityStore.open(path: dbPath, factory: databaseFactoryFfi);
      await store.setMeta(
        'client_notice',
        jsonEncode({
          ...ClientNotice.fallback,
          'message': '합성 필수 안내',
          'min_version': {'pc': null, 'mobile': '99.0.0'},
        }),
      );
    });
    ClientNotice.versionProvider = () async => '1.0.0';
    addTearDown(() async {
      ClientNotice.current.value = null;
      await tester.runAsync(() async {
        await CommunityStore.closeForTest(dbPath);
        await tmp.delete(recursive: true);
      });
    });
    Widget app() => MaterialApp(
      navigatorKey: communityAuthNavigatorKey,
      builder: (context, child) => ClientNoticeHost(store: store, child: child!),
      home: const Scaffold(body: Text('신고내역')),
    );
    await tester.pumpWidget(app());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    // Same day, same notice: a rebuilt host must not show it again.
    await tester.pumpWidget(const SizedBox.shrink());
    ClientNotice.current.value = null;
    await tester.pumpWidget(app());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
  });
}
