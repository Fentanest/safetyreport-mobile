import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/services/db_export_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fentanest.mysafetyreport/permissions');
  const saved = SavedDbExport(
    uri: 'content://downloads/42',
    filename: 'fixture.db',
    location: 'Download/mysafetyreport/fixture.db',
    downloads: true,
  );
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'completed document metadata is retained; SAF cancellation returns no completed file',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return calls.length == 1 ? saved.arguments : null;
          });
      final result = await DbExportLocation.publish(
        File('/fixture/cache/fixture.db'),
      );
      expect(result!.arguments, saved.arguments);
      expect(calls.single.arguments, {
        'path': '/fixture/cache/fixture.db',
        'filename': 'fixture.db',
      });
      expect(
        await DbExportLocation.publish(File('/fixture/cache/fixture.db')),
        isNull,
      );
    },
  );
  test(
    'missing file application is recoverable and does not fabricate a URI',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'NO_ACTIVITY');
          });
      expect(await DbExportLocation.open(saved), isFalse);
      expect(calls.single.arguments, {
        ...saved.arguments,
        'action': 'location',
      });
    },
  );
  testWidgets(
    'background completion posts notification without opening another app',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold();
            },
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await DbExportLocation.completed(context, saved);
      expect(calls.map((c) => c.method), ['notifyDbExport']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
  testWidgets(
    'file application failure shows actual location with open and share alternatives',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return false;
          });
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const Scaffold();
            },
          ),
        ),
      );
      final pending = DbExportLocation.showLocation(context, saved);
      await tester.pumpAndSettle();
      expect(find.textContaining(saved.filename), findsOneWidget);
      expect(find.text('파일 열기'), findsOneWidget);
      expect(find.text('공유'), findsOneWidget);
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      await pending;
    },
  );
}
