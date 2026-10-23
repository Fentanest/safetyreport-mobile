/// 공유 목록 확인 결과. 진단에는 응답 본문·계정·연결 ID·토큰을 넣지 않는다.
enum ManifestStatus {
  ok('ok'),
  busyUploadLease('busy_upload_lease'),
  noContext('no_context'),
  noToken('no_token'),
  paused('paused'),
  auth('auth'),
  consentRequired('consent_required'),
  writerRequired('writer_required'),
  rateLimited('rate_limited'),
  serverError('server_error'),
  network('network'),
  invalidResponse('invalid_response');

  const ManifestStatus(this.code);
  final String code;
}

enum RebuildRecoveryAction { login, consent, connection }

class ManifestResult {
  const ManifestResult(
    this.status, {
    this.httpStatus,
    this.serverCode,
    this.requestId,
    this.page,
  });

  final ManifestStatus status;
  final int? httpStatus;
  final String? serverCode;
  final String? requestId;
  final Map<String, Object?>? page;
  ManifestResult withStatus(ManifestStatus next) => ManifestResult(
    next,
    httpStatus: httpStatus,
    serverCode: serverCode,
    requestId: requestId,
  );

  bool get isOk => status == ManifestStatus.ok;
  String get jobError => 'manifest_${status.code}';
  bool get retryable => const {
    ManifestStatus.busyUploadLease,
    ManifestStatus.paused,
    ManifestStatus.rateLimited,
    ManifestStatus.serverError,
    ManifestStatus.network,
  }.contains(status);

  RebuildRecoveryAction? get action => switch (status) {
    ManifestStatus.noToken ||
    ManifestStatus.auth => RebuildRecoveryAction.login,
    ManifestStatus.consentRequired => RebuildRecoveryAction.consent,
    ManifestStatus.noContext ||
    ManifestStatus.writerRequired => RebuildRecoveryAction.connection,
    _ => null,
  };

  String? get actionLabel => switch (action) {
    RebuildRecoveryAction.login => '카카오 다시 로그인',
    RebuildRecoveryAction.consent => '새 동의문 확인',
    RebuildRecoveryAction.connection => '공유 연결 확인',
    null => null,
  };

  String get message => switch (status) {
    ManifestStatus.ok => '공유 목록을 확인했습니다.',
    ManifestStatus.busyUploadLease => '신고 자료를 보내고 있습니다. 전송이 끝나면 자동으로 다시 시도합니다.',
    ManifestStatus.noContext =>
      '공유 연결을 확인해 주세요. 다른 기기가 업로드 중이면 ‘이 기기로 업로드 전환’을 선택해 주세요.',
    ManifestStatus.writerRequired =>
      '다른 기기가 업로드하고 있습니다. 공유 연결 화면에서 ‘이 기기로 업로드 전환’을 선택해 주세요.',
    ManifestStatus.noToken ||
    ManifestStatus.auth => '카카오 계정을 확인하지 못했습니다. 카카오로 다시 로그인해 주세요.',
    ManifestStatus.consentRequired =>
      '공유 동의문이 바뀌었거나 동의가 필요합니다. 새 동의문을 확인하고 동의해 주세요.',
    ManifestStatus.paused => '공유 서버를 점검하고 있습니다. 잠시 후 자동으로 다시 시도합니다.',
    ManifestStatus.rateLimited => '공유 서버에 요청이 많습니다. 잠시 후 자동으로 다시 시도합니다.',
    ManifestStatus.serverError ||
    ManifestStatus.network => '공유 서버에 연결하지 못했습니다. 잠시 후 자동으로 다시 시도합니다.',
    ManifestStatus.invalidResponse =>
      '공유 목록을 안전하게 확인하지 못했습니다. 기존 자료는 유지됩니다. 잠시 후 다시 시도해 주세요.',
  };

  /// 서버의 구조화된 코드와 요청 ID만 제한된 문자·길이로 보존한다.
  static String? diagnosticToken(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(value)
      ? value
      : null;

  Map<String, Object?> get diagnostics => {
    'reason': status.code,
    'http_status': httpStatus,
    'server_code': diagnosticToken(serverCode),
    'request_id': diagnosticToken(requestId),
  };

  static ManifestResult? fromJobError(Object? error) {
    if (error == 'manifest_unavailable') {
      return const ManifestResult(ManifestStatus.network);
    }
    for (final status in ManifestStatus.values) {
      if (error == 'manifest_${status.code}') return ManifestResult(status);
    }
    return null;
  }

  static ManifestStatus statusForCode(String? code) => switch (code) {
    'consent_missing' ||
    'consent_grant_unknown' ||
    'consent_required' ||
    'consent_outdated' ||
    'consent_revoked' ||
    'policy_changed' ||
    'policy_mismatch' ||
    'consent_none' ||
    'consent_version_mismatch' => ManifestStatus.consentRequired,
    'writer_superseded' ||
    'writer_conflict' ||
    'connection_superseded' ||
    'writer_epoch_mismatch' => ManifestStatus.writerRequired,
    'connection_unknown' ||
    'connection_revoked' ||
    'connection_suspended' ||
    'connection_session_mismatch' ||
    'connection_mode_mismatch' => ManifestStatus.noContext,
    'kakao_required' ||
    'kakao_reauth_required' ||
    'session_unreadable' => ManifestStatus.noToken,
    'verification_required' ||
    'cloud_unavailable' ||
    'cloud_cooldown' => ManifestStatus.network,
    'maintenance' => ManifestStatus.paused,
    _ => ManifestStatus.auth,
  };
}
