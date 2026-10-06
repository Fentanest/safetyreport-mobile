import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/main.dart';
import 'package:safetyreport/screens/setup_screen.dart';
import 'package:safetyreport/services/local_db_service.dart';
import 'package:safetyreport/widgets/official_account_reset_dialog.dart';

void main() {
  testWidgets(
    'legacy binding rejection opens relogin with notice before rebuild/main',
    (tester) async {
      var skipped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StandaloneRebuildGate(
            onDone: () => skipped = true,
            prepare: () async => throw ForeignDatabaseException(
              LocalDbService.officialResetMessage,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(find.text(LocalDbService.officialResetMessage), findsOneWidget);
      expect(skipped, isFalse);
    },
  );

  for (final confirm in [false, true]) {
    testWidgets(
      'official reset notice ${confirm ? 'confirms' : 'cancels'} explicitly',
      (tester) async {
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await confirmOfficialAccountReset(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('안전신문고 계정별 자료 분리'), findsOneWidget);
        expect(find.textContaining('감시 목록을 비우고'), findsOneWidget);
        expect(result, isNull);
        await tester.tap(find.text(confirm ? '자료 비우고 계속' : '취소'));
        await tester.pumpAndSettle();
        expect(result, confirm);
      },
    );
  }
}
