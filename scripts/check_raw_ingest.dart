// Offline cross-language vectors; runs with the pinned Dart SDK without native asset hooks.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:safetyreport/community/capture/raw_ingest.dart';
import 'package:safetyreport/community/gate/gate_policy.dart';
import 'package:safetyreport/community/upload/upload_policy.dart' as policy;
void check(bool value, String name) { if (!value) throw StateError(name); }
void main() {
  final wire=jsonDecode(File('contracts/community-ingest-v2/vectors/wire.json').readAsStringSync()) as Map;
  final e=((wire['envelope'] as Map)['events'] as List).first as Map;
  check(rawCanonicalHash((e['supplement'] as Map).cast<String,Object?>())==e['supplement_sha256'],'supplement');
  check(rawCanonicalHash((e['client_observation'] as Map).cast<String,Object?>())==e['client_observation_sha256'],'observation');
  check(sha256.convert(utf8.encode(jsonEncode(wire['envelope']))).toString()==wire['request_utf8_sha256'],'wire');
  for (final c in wire['raw_hash_cases'] as List) {
    check(sha256.convert(utf8.encode(c['body'] as String)).toString()==c['sha256'],'raw hash');
    check(utf8.encode(c['body'] as String).length==c['size'],'raw size');
  }
  final gates=jsonDecode(File('test/fixtures/review_gate_cases.json').readAsStringSync()) as Map;
  for(final c in gates['cases'] as List) {
    check(gatePolicy((c['input'] as Map).cast<String,Object?>())==c['expected'],c['name'] as String);
  }
  const id='11111111-1111-4111-8111-111111111111';
  final ack={'protocol':2,'request_id':'synthetic','results':[{'event_id':id,'status':'stored','durable':true,'receipt_id':id,'projection_status':'parse_pending'}]};
  check(policy.interpretAck([id],ack,protocol:2).events[id]?.outcome=='done','stored ACK');
  check(policy.interpretAck([id],ack).errorClass=='invalid_ack','protocol mismatch');
  for(final line in File('contracts/community-ingest-v2/MANIFEST.sha256').readAsLinesSync()) {
    final parts=line.split('  ');check(sha256.convert(File('contracts/community-ingest-v2/${parts[1]}').readAsBytesSync()).toString()==parts[0],parts[1]);
  }
  stdout.writeln('PASS: ${(gates['cases'] as List).length} gate vectors, 4 raw byte vectors, envelope/supplement/observation hashes, ACK protocol and contract manifest');
}
