#!/usr/bin/env bash

resolve_abs_path() {
  local target="$1"
  local target_dir

  target_dir="$(cd "$(dirname "$target")" && pwd)"
  printf '%s/%s\n' "$target_dir" "$(basename "$target")"
}

ensure_flutter_available() {
  local flutter_bin="${1:-flutter}"

  if ! command -v "$flutter_bin" >/dev/null 2>&1; then
    echo "❌ flutter 명령을 찾을 수 없습니다: $flutter_bin" >&2
    return 1
  fi
}

# gradle(=flutter build apk/appbundle)는 JDK 가 필요하다.
# GitHub Actions self-hosted 러너는 대화형 셸 PATH 를 물려받지 못해
# JAVA_HOME 미설정 + java 미탐색으로 "JAVA_HOME is not set ..." 에러가 난다.
# 유효한 JAVA_HOME 이 이미 있으면 존중하고, 없으면 흔한 JDK 후보를 탐색해 설정한다.
# 필요하면 JAVA_HOME 환경변수로 명시 지정해 이 로직을 건너뛸 수 있다.
ensure_java_available() {
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    export PATH="${JAVA_HOME}/bin:${PATH}"
    echo "☕ JAVA_HOME=$JAVA_HOME (기존 설정 사용)"
    return 0
  fi

  # Android Studio 번들 JBR(Flutter/Gradle 호환 보장)을 우선, 그다음 시스템 JDK 17→21.
  local candidates=(
    "$HOME/development/android-studio/jbr"
    "/opt/android-studio/jbr"
    "/usr/lib/jvm/java-17-openjdk-amd64"
    "/usr/lib/jvm/java-21-openjdk-amd64"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate/bin/java" ]]; then
      export JAVA_HOME="$candidate"
      export PATH="${JAVA_HOME}/bin:${PATH}"
      echo "☕ JAVA_HOME=$JAVA_HOME"
      return 0
    fi
  done

  # 마지막으로 PATH 에 java 가 있으면 그대로 사용.
  if command -v java >/dev/null 2>&1; then
    echo "☕ java found in PATH: $(command -v java)"
    return 0
  fi

  echo "❌ Java(JDK)를 찾을 수 없습니다. JAVA_HOME 을 설정하거나 JDK 17+ 를 설치하세요." >&2
  return 1
}

sync_pubspec_version() {
  local repo_dir="$1"
  local version="$2"

  sed -i "s/^version:.*/version: $version/" "$repo_dir/pubspec.yaml"
  echo "✅ pubspec.yaml version synced to $version"
}

ANDROID_SIGNING_KEY_PROPERTIES=""
ANDROID_SIGNING_KEY_PROPERTIES_BACKUP=""

stage_android_signing_files() {
  local repo_dir="$1"
  local key_properties_source="$2"
  local keystore_source="$3"
  local android_dir="$repo_dir/android"
  local escaped_keystore_source

  ANDROID_SIGNING_KEY_PROPERTIES="$android_dir/key.properties"
  ANDROID_SIGNING_KEY_PROPERTIES_BACKUP=""

  if [[ -e "$ANDROID_SIGNING_KEY_PROPERTIES" ]]; then
    ANDROID_SIGNING_KEY_PROPERTIES_BACKUP="$(mktemp "$android_dir/key.properties.backup.XXXXXX")"
    mv "$ANDROID_SIGNING_KEY_PROPERTIES" "$ANDROID_SIGNING_KEY_PROPERTIES_BACKUP"
  fi

  cp "$key_properties_source" "$ANDROID_SIGNING_KEY_PROPERTIES"

  escaped_keystore_source="$(printf '%s\n' "$keystore_source" | sed 's/[&|]/\\&/g')"
  if grep -Eq '^[[:space:]]*storeFile[[:space:]]*=' "$ANDROID_SIGNING_KEY_PROPERTIES"; then
    sed -i "s|^[[:space:]]*storeFile[[:space:]]*=.*$|storeFile=$escaped_keystore_source|" "$ANDROID_SIGNING_KEY_PROPERTIES"
  else
    printf '\nstoreFile=%s\n' "$keystore_source" >> "$ANDROID_SIGNING_KEY_PROPERTIES"
  fi
}

cleanup_android_signing_files() {
  if [[ -z "${ANDROID_SIGNING_KEY_PROPERTIES:-}" ]]; then
    return 0
  fi

  if [[ -f "$ANDROID_SIGNING_KEY_PROPERTIES" ]]; then
    rm -f "$ANDROID_SIGNING_KEY_PROPERTIES"
  fi

  if [[ -n "${ANDROID_SIGNING_KEY_PROPERTIES_BACKUP:-}" && -f "$ANDROID_SIGNING_KEY_PROPERTIES_BACKUP" ]]; then
    mv "$ANDROID_SIGNING_KEY_PROPERTIES_BACKUP" "$ANDROID_SIGNING_KEY_PROPERTIES"
  fi
}

# 커뮤니티 공개 설정 주입 (T6).
#
#   prepare_community_public_config <repo_dir> <release|debug>
#
# COMMUNITY_SUPABASE_URL / COMMUNITY_SUPABASE_PUBLISHABLE_KEY 환경변수를 읽어
# allowlist JSON build/community_public.json(2키만)을 만들고
# COMMUNITY_DART_DEFINE_ARGS 배열에 --dart-define-from-file 인자를 둔다.
# release 에서는 비었거나 자리표시자·비밀이면 실패한다. debug 는 값 없이도
# 빌드되지만 앱은 config_invalid 게이트로 잠긴다.
COMMUNITY_DART_DEFINE_ARGS=()

_is_community_placeholder() {
  local value="$1"
  case "$value" in
    *"<"*|*"..."*|*"PROJECT_REF"*|*"example."*|*"EXAMPLE"*)
      return 0
      ;;
  esac
  return 1
}

_is_community_secret_key() {
  local key="$1"
  case "$key" in
    sb_secret_*)
      return 0
      ;;
  esac
  # 옛 JWT 형식: payload 의 role 이 service_role 이면 거부.
  if [[ "$key" == *.*.* ]]; then
    local payload_b64
    payload_b64="$(printf '%s' "$key" | cut -d'.' -f2)"
    local role
    role="$(python3 -c 'import base64,json,sys; s=sys.argv[1]; s+="="*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s).decode()).get("role",""))' "$payload_b64" 2>/dev/null || true)"
    if [[ "$role" == "service_role" ]]; then
      return 0
    fi
  fi
  return 1
}

prepare_community_public_config() {
  local repo_dir="$1"
  local mode="${2:-debug}"
  local url="${COMMUNITY_SUPABASE_URL:-}"
  local key="${COMMUNITY_SUPABASE_PUBLISHABLE_KEY:-}"
  local out_dir="$repo_dir/build"
  local out_file="$out_dir/community_public.json"

  COMMUNITY_DART_DEFINE_ARGS=()

  if [[ -z "$url" || -z "$key" ]]; then
    if [[ "$mode" == "release" ]]; then
      echo "❌ COMMUNITY_SUPABASE_URL / COMMUNITY_SUPABASE_PUBLISHABLE_KEY 가 비어 있습니다 (release 빌드 중단)." >&2
      return 1
    fi
    echo "⚠️ 커뮤니티 공개 설정이 없어 기본값으로 빌드합니다 (앱은 config_invalid 게이트로 잠김)."
    return 0
  fi

  if [[ "$mode" == "release" ]]; then
    if _is_community_placeholder "$url" || _is_community_placeholder "$key"; then
      echo "❌ 커뮤니티 공개 설정에 자리표시자가 있습니다 (release 빌드 중단)." >&2
      return 1
    fi
    if _is_community_secret_key "$key"; then
      echo "❌ 커뮤니티 설정에 비밀 키(secret/service_role)가 들어 있습니다 (release 빌드 중단)." >&2
      return 1
    fi
    case "$url" in
      https://*)
        ;;
      *)
        echo "❌ COMMUNITY_SUPABASE_URL 은 https 여야 합니다: $url" >&2
        return 1
        ;;
    esac
  fi

  mkdir -p "$out_dir"
  python3 - "$out_file" "$url" "$key" <<'EOF'
import json, sys
path, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"COMMUNITY_SUPABASE_URL": url, "COMMUNITY_SUPABASE_PUBLISHABLE_KEY": key}, f)
EOF
  COMMUNITY_DART_DEFINE_ARGS=(--dart-define-from-file="$out_file")
  echo "✅ 커뮤니티 공개 설정 주입: $out_file"
}

# ── Flutter 고정 버전(tool/flutter-version) ─────────────────────────────────
#
#   resolve_pinned_flutter <repo_dir>
#
# FLUTTER_BIN(기본 flutter)이 고정 버전이면 그대로, 아니면 ~/development/flutter-<버전>/bin/flutter 를 찾는다.
# 둘 다 아니면 실패한다(전역 SDK 는 바꾸지 않는다). 결과는 FLUTTER_BIN 에 둔다.
resolve_pinned_flutter() {
  local repo_dir="$1"
  local pinned
  pinned="$(tr -d '[:space:]' < "$repo_dir/tool/flutter-version")"
  local candidate actual
  for candidate in "${FLUTTER_BIN:-flutter}" "$HOME/development/flutter-$pinned/bin/flutter"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      actual="$("$candidate" --version --machine 2>/dev/null | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["frameworkVersion"])' 2>/dev/null || true)"
      if [[ "$actual" == "$pinned" ]]; then
        FLUTTER_BIN="$candidate"
        echo "✅ Flutter $actual ($candidate)"
        return 0
      fi
      echo "ℹ️ $candidate 는 Flutter ${actual:-?} — 고정 버전 $pinned 이 아니다"
    fi
  done
  echo "❌ Flutter $pinned 이 필요합니다(tool/flutter-version). FLUTTER_BIN 으로 지정하세요." >&2
  return 1
}

# ── 산출물·mapping 보존 ─────────────────────────────────────────────────────
#
#   preserve_android_outputs <repo_dir> <apk|aab> <artifact_path> <dist_dir> <expect_release_key:1|0>
#
# 그 빌드 직후(다음 빌드가 build/.../mapping 을 덮어쓰기 전에) 산출물과 R8 출력(mapping·configuration·usage·seeds·
# resources)을 dist/<kind>/ 에 함께 복사하고, 서명 인증서(공개 정보)와 SHA-256 을 기록한다. mapping 이 없으면(R8 미적용) 실패.
# expect_release_key=1 인데 Android Debug 인증서로 서명돼 있으면 실패한다.
preserve_android_outputs() {
  local repo_dir="$1" kind="$2" artifact="$3" dist_dir="$4" expect_release="$5"
  local out="$dist_dir/$kind"
  local mapping_dir="$repo_dir/build/app/outputs/mapping/release"
  mkdir -p "$out"
  cp "$artifact" "$out/"
  local f
  for f in mapping.txt configuration.txt usage.txt seeds.txt resources.txt; do
    if [[ -f "$mapping_dir/$f" ]]; then
      cp "$mapping_dir/$f" "$out/$f"
    fi
  done
  if [[ ! -s "$out/mapping.txt" ]]; then
    echo "❌ $kind: R8 mapping.txt 가 없습니다(축소·난독화 미적용?)" >&2
    return 1
  fi
  local cert
  if ! cert="$(android_signing_cert "$kind" "$artifact")"; then
    echo "❌ $kind: 서명 인증서를 확인하지 못했습니다" >&2
    return 1
  fi
  printf '%s\n' "$cert" > "$out/signing-cert.txt"
  if [[ "$expect_release" == "1" ]]; then
    if grep -q "CN=Android Debug" "$out/signing-cert.txt"; then
      echo "❌ $kind: 배포용 빌드가 Android Debug 인증서로 서명됐습니다" >&2
      return 1
    fi
    # 선택: 배포 인증서 SHA-256 지문(공개 정보)을 알려 주면 정확히 대조한다(콜론·대소문자 무시).
    if [[ -n "${EXPECTED_RELEASE_CERT_SHA256:-}" ]]; then
      local want got
      want="$(printf '%s' "$EXPECTED_RELEASE_CERT_SHA256" | tr -d ': ' | tr 'A-F' 'a-f')"
      got="$(tr -d ': ' < "$out/signing-cert.txt" | tr 'A-F' 'a-f')"
      if [[ "$got" != *"$want"* ]]; then
        echo "❌ $kind: 서명 인증서 지문이 EXPECTED_RELEASE_CERT_SHA256 과 다릅니다" >&2
        return 1
      fi
    fi
  fi
  (cd "$out" && sha256sum -- * > SHA256SUMS)
  echo "✅ $kind 보존: $out ($(grep -m1 '^# pg_map_id' "$out/mapping.txt" || echo 'pg_map_id 없음'))"
}

# 서명 인증서 요약(소유자·SHA-256 지문 — 공개 정보). APK 는 apksigner, AAB 는 keytool.
# 도구가 없거나 검사가 실패하거나 소유자·SHA-256 두 줄을 읽지 못하면 실패(1)를 돌려준다 — 실패를 성공처럼 기록하지 않는다.
android_signing_cert() {
  local kind="$1" artifact="$2" out
  if [[ "$kind" == "apk" ]]; then
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
    local apksigner
    apksigner="$(ls -d "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"
    [[ -n "$apksigner" ]] || { echo "apksigner 없음" >&2; return 1; }
    out="$("$apksigner" verify --print-certs "$artifact" 2>&1)" || { echo "$out" >&2; return 1; }
    # 도구 판에 따라 "Signer #1 certificate DN:" 또는 "V2 Signer: certificate DN:" 형식
    out="$(printf '%s\n' "$out" | grep -E "^(Signer #1|V[0-9]+ Signer:) certificate (DN|SHA-256 digest):" | head -2)"
  else
    out="$(keytool -printcert -jarfile "$artifact" 2>&1)" || { echo "$out" >&2; return 1; }
    out="$(printf '%s\n' "$out" | grep -E "^(Owner|소유자):|^[[:space:]]+SHA256:" | head -2)"
  fi
  [[ "$(printf '%s\n' "$out" | grep -c .)" == "2" ]] || { echo "인증서 정보를 읽지 못함" >&2; return 1; }
  printf '%s\n' "$out"
}

#   write_android_build_meta <repo_dir> <dist_dir> <build_name> <build_number> <signing_label>
write_android_build_meta() {
  local repo_dir="$1" dist_dir="$2" build_name="$3" build_number="$4" signing="$5"
  local flutter_json java_version
  flutter_json="$("$FLUTTER_BIN" --version --machine 2>/dev/null)"
  java_version="$(java -version 2>&1 | head -1)"
  python3 - "$repo_dir" "$dist_dir" "$build_name" "$build_number" "$signing" "$flutter_json" "$java_version" <<'PY'
import json, os, re, subprocess, sys
repo, dist, name, number, signing, flutter_raw, java = sys.argv[1:8]
flutter = json.loads(flutter_raw[flutter_raw.index("{"):]) if "{" in flutter_raw else {}
def grab(path, pattern):
    try:
        m = re.search(pattern, open(os.path.join(repo, path), encoding="utf-8").read())
        return m.group(1) if m else None
    except OSError:
        return None
def sha(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
outputs = {}
for kind in ("apk", "aab"):
    d = os.path.join(dist, kind)
    if not os.path.isdir(d):
        continue
    files = {f: sha(os.path.join(d, f)) for f in sorted(os.listdir(d)) if f != "SHA256SUMS"}
    pg = None
    mp = os.path.join(d, "mapping.txt")
    if os.path.exists(mp):
        with open(mp, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not line.startswith("#"):
                    break
                if line.startswith("# pg_map_id"):
                    pg = line.split(":", 1)[1].strip()
    cert = open(os.path.join(d, "signing-cert.txt"), encoding="utf-8").read().strip() if os.path.exists(os.path.join(d, "signing-cert.txt")) else None
    outputs[kind] = {"files": files, "pg_map_id": pg, "signing_cert": cert}
commit = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
dirty = bool(subprocess.run(["git", "-C", repo, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip())
meta = {
    "version": f"{name}+{number}", "commit": commit, "worktree_dirty": dirty, "signing": signing,
    "flutter": flutter.get("frameworkVersion"), "dart": flutter.get("dartSdkVersion"),
    "agp": grab("android/settings.gradle.kts", r'com\.android\.application"\)\s+version\s+"([^"]+)"'),
    "kgp": grab("android/settings.gradle.kts", r'org\.jetbrains\.kotlin\.android"\)\s+version\s+"([^"]+)"'),
    "gradle": grab("android/gradle/wrapper/gradle-wrapper.properties", r"gradle-([0-9.]+)-"),
    "jdk": java, "outputs": outputs,
}
with open(os.path.join(dist, "build-meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
print("✅ build-meta.json:", os.path.join(dist, "build-meta.json"))
PY
}
