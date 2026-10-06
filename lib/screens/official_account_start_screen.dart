import 'package:flutter/material.dart';
import '../services/local_db_service.dart';

/// 계정 변경 완료 안내는 앱이 종료돼도 다음 시작에 다시 표시한다.
class OfficialAccountStartScreen extends StatefulWidget {
  const OfficialAccountStartScreen({super.key, required this.child});
  final Widget child;

  @override
  State<OfficialAccountStartScreen> createState() =>
      _OfficialAccountStartState();
}

class _OfficialAccountStartState extends State<OfficialAccountStartScreen> {
  late Future<String?> _pending = LocalDbService.getMeta(
    LocalDbService.officialRestartKey,
  );
  bool _done = false;
  String? _error;

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _pending,
    builder: (context, snapshot) {
      if (_done ||
          (snapshot.connectionState == ConnectionState.done &&
              !snapshot.hasError &&
              snapshot.data != 'true')) {
        return widget.child;
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) {
        return PopScope(
          canPop: false,
          child: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('개인 DB를 확인하지 못했습니다. 다시 시도해 주세요.'),
                  FilledButton(
                    onPressed: () => setState(() {
                      _pending = LocalDbService.getMeta(
                        LocalDbService.officialRestartKey,
                      );
                    }),
                    child: const Text('재시도'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return PopScope(
        canPop: false,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('새로 시작'),
            automaticallyImplyLeading: false,
          ),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '기존 개인 DB를 백업하고 계정별 자료를 초기화했습니다.\n로그인한 안전신문고 계정으로 새로 시작합니다.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null || snapshot.hasError)
                    const Text('설정을 저장하지 못했습니다. 다시 시도해 주세요.'),
                  FilledButton(
                    onPressed: () async {
                      try {
                        await LocalDbService.setMeta(
                          LocalDbService.officialRestartKey,
                          'false',
                        );
                        if (mounted) setState(() => _done = true);
                      } catch (_) {
                        if (mounted) setState(() => _error = 'save_failed');
                      }
                    },
                    child: const Text('새 계정으로 시작'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
