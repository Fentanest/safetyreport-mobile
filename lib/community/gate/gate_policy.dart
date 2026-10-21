/// Shared G1–G11 contract model. `last_g1` and `now` use Unix seconds.
bool offlineGrace(num? last, num now, bool sameMember) =>
    last != null && sameMember && now - last >= 0 && now - last <= 72 * 3600;
String gatePolicy(Map<String, Object?> v) {
  if (v['owner'] != true) return 'owner_mismatch';
  if (v['binding'] != true) return 'binding_mismatch';
  if (v['reauth'] == true) return 'reauth_required';
  if (v['session'] != true) return 'login_required';
  if (v['confirmed'] != true) {
    return offlineGrace(
          v['last_g1'] as num?,
          v['now'] as num,
          v['same_member'] == true,
        )
        ? 'local_only'
        : 'connection_required';
  }
  if (v['contributor'] == 'suspended') return 'suspended';
  final prior = v['last_g1'] != null && v['same_member'] == true;
  if (v['kakao'] != true) {
    final explicit =
        v['kakao'] == false &&
        (v['reasons'] is List) &&
        (v['reasons'] as List).contains('kakao_missing');
    if (!explicit) return 'connection_required';
    return prior ? 'soft_reset' : 'login_required';
  }
  if (v['contributor'] == 'none' && prior) return 'soft_reset';
  if (v['consent'] == 'revoked') {
    return prior ? 'soft_reset' : 'consent_required';
  }
  if (v['consent'] != 'active') return 'consent_required';
  return v['contributor'] == 'active' ? 'use_upload' : 'connection_required';
}

/// The status fields [gatePolicy] reads, for a verified (`confirmed`) answer on a signed-in,
/// owner-matching device. [hadG1] is true when this device saw a G1 for the same member.
Map<String, Object?> gateVector(Map<String, Object?> status, bool hadG1) {
  final gate = status['gate'], contributor = status['contributor'];
  final consent = status['consent'];
  return {
    'owner': true,
    'binding': true,
    'reauth': false,
    'session': true,
    'confirmed': true,
    'now': 0,
    'same_member': hadG1,
    'last_g1': hadG1 ? 1 : null,
    'kakao': gate is Map ? gate['kakao'] : null,
    'reasons': gate is Map ? gate['reasons'] : null,
    'contributor': contributor is Map ? contributor['status'] : null,
    'consent': consent is Map ? consent['state'] : null,
  };
}
