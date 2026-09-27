import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/gate/community_device_label.dart';

void main() {
  test('Android 기기 이름을 중앙 연결 라벨로 정리한다', () {
    expect(CommunityDeviceLabel.normalize('  예지의   S23  '), '예지의 S23');
    expect(CommunityDeviceLabel.normalize('예지의 <S23>'), '예지의 S23');
    expect(CommunityDeviceLabel.normalize('https://example.com'), 'Android 기기');
    expect(CommunityDeviceLabel.normalize(''), 'Android 기기');
    expect(
      CommunityDeviceLabel.normalize(List.filled(41, '가').join()).runes.length,
      40,
    );
  });

  test('연결 기기에는 내부 epoch 대신 알아볼 수 있는 이름과 상태를 표시한다', () {
    expect(
      CommunityDeviceLabel.connectionDisplayName({
        'source_app': 'safetyreport-mobile',
        'writer_epoch': 2,
        'status': 'active',
      }, '예지의 S23'),
      '예지의 S23 · 연결됨',
    );
    expect(
      CommunityDeviceLabel.connectionDisplayName({
        'source_app': 'safetyreport',
        'writer_epoch': 4,
        'status': 'superseded',
      }, null),
      'PC 서버 · 다른 기기로 전환됨',
    );
  });
}
