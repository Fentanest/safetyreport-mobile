import 'package:flutter/material.dart';

import '../widgets/community_upload_panel.dart';

/// 신고 공유(업로드) 현황만 보이는 화면 — 사용자 조치 알림(올리지 못한 신고·앱을 열어 달라는 안내)을 누르면 연다.
/// 지도 화면의 같은 패널([CommunityUploadPanelHost])을 그대로 쓴다.
class CommunityUploadScreen extends StatelessWidget {
  const CommunityUploadScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('신고 공유')),
    body: const SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: CommunityUploadPanelHost(),
    ),
  );
}
