import '../widgets/cloud_delay_banner.dart';
import 'package:flutter/material.dart';
import '../community/gate/community_gate.dart';

/// 클라우드 대조 실패는 기존 성공 캐시로 우회하지 않는다.
class CloudUnavailableScreen extends StatelessWidget {
  const CloudUnavailableScreen({super.key, required this.gate});
  final CommunityGate gate;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ListenableBuilder(
              listenable: gate,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 48),
                  const SizedBox(height: 20),
                  const Text(
                    CommunityGate.cloudUnavailableMessage,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '잠시 기다리면 자동으로 다시 연결합니다.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  CloudDelayBanner(gate: gate),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
