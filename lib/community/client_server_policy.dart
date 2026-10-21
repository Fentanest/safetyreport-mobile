/// What the connected PC said about Client browsing.
///
/// - [permitted]: a strict `true` in `can_local` / `can_browse` / `can_enter`.
/// - [refused]: the PC answered and explicitly said no (a strict `false` with no `true`, or the
///   onboarding-required refusal).
/// - [unknown]: no answer (offline, timeout, 5xx, malformed, no server configured). This is NOT a
///   refusal: the Client keeps its previous behaviour and only shows "server check pending".
enum ServerConsentVerdict { permitted, refused, unknown }

ServerConsentVerdict serverConsentVerdict(
  Map<String, dynamic>? data, {
  bool onboardingRequired = false,
}) {
  if (onboardingRequired) return ServerConsentVerdict.refused;
  if (data == null) return ServerConsentVerdict.unknown;
  final flags = [data['can_local'], data['can_browse'], data['can_enter']];
  if (flags.any((v) => v == true)) return ServerConsentVerdict.permitted;
  if (flags.any((v) => v == false)) return ServerConsentVerdict.refused;
  return ServerConsentVerdict.unknown;
}

/// Kept for callers that only need the strict "may enter" answer.
bool serverConsentAllows(Map<String, dynamic>? data) =>
    serverConsentVerdict(data) == ServerConsentVerdict.permitted;
