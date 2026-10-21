import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safetyreport/community/capture/raw_ingest.dart';
import 'package:safetyreport/community/gate/gate_policy.dart';
import 'package:safetyreport/community/upload/upload_policy.dart' as policy;
void main() {
  test('v2 canonical bytes/hashes and manifest', () {
    final v=jsonDecode(File('contracts/community-ingest-v2/vectors/wire.json').readAsStringSync()) as Map;
    final event=((v['envelope'] as Map)['events'] as List).first as Map;
    final supplement=(event['supplement'] as Map).cast<String,Object?>();
    expect(rawCanonicalHash(supplement),event['supplement_sha256']);
    expect(sha256.convert(utf8.encode((event['raw'] as Map)['body'] as String)).toString(),(event['raw'] as Map)['sha256']);
    expect(sha256.convert(utf8.encode(jsonEncode(v['envelope']))).toString(),v['request_utf8_sha256']);
    for (final line in File('contracts/community-ingest-v2/MANIFEST.sha256').readAsLinesSync()) {
      final parts=line.split('  ');expect(sha256.convert(File('contracts/community-ingest-v2/${parts[1]}').readAsBytesSync()).toString(),parts[0]);
    }
  });
  test('shared G1–G11 vectors including grace boundary and reversed clock', () {
    final v=jsonDecode(File('test/fixtures/review_gate_cases.json').readAsStringSync()) as Map;
    for(final c in v['cases'] as List) {
      expect(gatePolicy((c['input'] as Map).cast<String,Object?>()),c['expected'],reason:c['name'] as String);
    }
  });
  test('stored acknowledgement requires the sent protocol', () {
    const id='11111111-1111-4111-8111-111111111111';
    final ack={'protocol':2,'request_id':'synthetic','results':[{'event_id':id,'status':'stored','durable':true,'receipt_id':id,'projection_status':'parse_pending'}]};
    expect(policy.interpretAck([id],ack,protocol:2).events[id]!.outcome,'done');
    expect(policy.interpretAck([id],ack).errorClass,'invalid_ack');
  });
}
