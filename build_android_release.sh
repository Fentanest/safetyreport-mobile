#!/usr/bin/env bash
set -euo pipefail

# build-apk.yml 과 동일한 방식으로 로컬에서 Android release APK/AAB 를 빌드한다.
#
# 기본 동작:
# - Flutter 고정 버전 확인(tool/flutter-version — FLUTTER_BIN 이 다르면 ~/development/flutter-<버전> 사용, 없으면 실패)
# - VERSION 읽기, pubspec.yaml version 동기화
# - 외부 key.properties 를 android/key.properties 로 임시 배치(storeFile 을 키스토어 절대경로로 교정)
# - release APK 빌드 → 곧바로 APK 와 그 빌드의 R8 mapping·configuration·usage·seeds·resources 를 dist/…/apk 에 보존
#   → release AAB 빌드 → 같은 방식으로 dist/…/aab 에 보존(AAB 가 mapping 을 덮어쓰기 전에 APK 것을 따로 둔다)
# - 서명 인증서(공개 지문)·SHA-256·도구 버전을 dist/…/build-meta.json 에 기록, 산출물을 workflow 와 같은 이름으로 복사
#
# 검증 전용: ALLOW_DEBUG_SIGNED_RELEASE=1 이면 서명키 없이 debug 키로 서명한다. 산출물 이름에 DEBUG-SIGNED 를 붙이고
# 메타에 signing=debug 로 남긴다 — 배포용이 아니다(업로드·릴리즈에 쓰지 않는다).
#
# 환경변수로 명령/경로를 덮어쓸 수 있다.
#   FLUTTER_BIN
#   KEY_PROPERTIES_PATH
#   KEYSTORE_PATH
#   ALLOW_DEBUG_SIGNED_RELEASE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build_android_common.sh"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
KEY_PROPERTIES_PATH="${KEY_PROPERTIES_PATH:-$HOME/mysafetyreport-android/key.properties}"
KEYSTORE_PATH="${KEYSTORE_PATH:-$HOME/mysafetyreport-android/upload-keystore.jks}"

usage() {
  cat <<'EOF'
Usage: ./build_android_release.sh

Build release APK and AAB locally using the same Flutter CLI flow as
.github/workflows/build-apk.yml.

Optional environment variables:
  FLUTTER_BIN           Flutter executable to use
  KEY_PROPERTIES_PATH   Local path to key.properties
  KEYSTORE_PATH         Local path to upload-keystore.jks
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

resolve_pinned_flutter "$SCRIPT_DIR"
ensure_java_available
DEBUG_SIGNED="${ALLOW_DEBUG_SIGNED_RELEASE:-0}"

if [[ ! -f "$SCRIPT_DIR/VERSION" ]]; then
  echo "❌ VERSION 파일이 없습니다: $SCRIPT_DIR/VERSION" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
if [[ -z "$VERSION" ]]; then
  echo "❌ VERSION 파일에서 버전을 읽을 수 없습니다." >&2
  exit 1
fi

BUILD_NAME="${VERSION%%+*}"
BUILD_NUMBER="${VERSION##*+}"
if [[ -z "$BUILD_NAME" || -z "$BUILD_NUMBER" || "$BUILD_NAME" == "$BUILD_NUMBER" ]]; then
  echo "❌ VERSION 형식이 올바르지 않습니다. 기대 형식: 1.2.3+45" >&2
  exit 1
fi

if [[ "$DEBUG_SIGNED" != "1" ]]; then
  KEY_PROPERTIES_PATH="$(resolve_abs_path "$KEY_PROPERTIES_PATH")"
  KEYSTORE_PATH="$(resolve_abs_path "$KEYSTORE_PATH")"

  if [[ ! -f "$KEY_PROPERTIES_PATH" ]]; then
    echo "❌ key.properties 파일이 없습니다: $KEY_PROPERTIES_PATH" >&2
    exit 1
  fi

  if [[ ! -f "$KEYSTORE_PATH" ]]; then
    echo "❌ upload-keystore.jks 파일이 없습니다: $KEYSTORE_PATH" >&2
    exit 1
  fi
fi

trap cleanup_android_signing_files EXIT

echo "=========================================="
echo " Android release build"
echo " Version      : $BUILD_NAME+$BUILD_NUMBER"
echo " Flutter bin  : $FLUTTER_BIN"
echo " Repo         : $SCRIPT_DIR"
echo "=========================================="

sync_pubspec_version "$SCRIPT_DIR" "$VERSION"
if [[ "$DEBUG_SIGNED" == "1" ]]; then
  echo "⚠️ ALLOW_DEBUG_SIGNED_RELEASE=1 — debug 키 서명 검증 빌드(배포 불가)"
  prepare_community_public_config "$SCRIPT_DIR" debug
  SIGNING_LABEL="debug (검증 전용, 배포 불가)"
  NAME_SUFFIX="-DEBUG-SIGNED"
  EXPECT_RELEASE_KEY=0
else
  stage_android_signing_files "$SCRIPT_DIR" "$KEY_PROPERTIES_PATH" "$KEYSTORE_PATH"
  echo "✅ android/key.properties staged for local Flutter build"
  prepare_community_public_config "$SCRIPT_DIR" release
  echo "✅ community public config staged"
  SIGNING_LABEL="release"
  NAME_SUFFIX=""
  EXPECT_RELEASE_KEY=1
fi

SHORT_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
DIST_DIR="$SCRIPT_DIR/dist/$BUILD_NAME+$BUILD_NUMBER-$SHORT_SHA$NAME_SUFFIX"
if [[ -d "$DIST_DIR" ]]; then
  rm -rf -- "${DIST_DIR:?}"
fi
mkdir -p "$DIST_DIR"

"$FLUTTER_BIN" --version
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER" \
  "${COMMUNITY_DART_DEFINE_ARGS[@]}"
APK_BUILT="$SCRIPT_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_PATH="$SCRIPT_DIR/build/app/outputs/flutter-apk/mysafetyreport$NAME_SUFFIX.apk"
cp "$APK_BUILT" "$APK_PATH"
preserve_android_outputs "$SCRIPT_DIR" apk "$APK_PATH" "$DIST_DIR" "$EXPECT_RELEASE_KEY"

"$FLUTTER_BIN" build appbundle --release \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER" \
  "${COMMUNITY_DART_DEFINE_ARGS[@]}"
AAB_BUILT="$SCRIPT_DIR/build/app/outputs/bundle/release/app-release.aab"
AAB_PATH="$SCRIPT_DIR/build/app/outputs/bundle/release/mysafetyreport$NAME_SUFFIX.aab"
cp "$AAB_BUILT" "$AAB_PATH"
preserve_android_outputs "$SCRIPT_DIR" aab "$AAB_PATH" "$DIST_DIR" "$EXPECT_RELEASE_KEY"

write_android_build_meta "$SCRIPT_DIR" "$DIST_DIR" "$BUILD_NAME" "$BUILD_NUMBER" "$SIGNING_LABEL"

echo
echo "✅ 완료 (서명: $SIGNING_LABEL)"
echo " APK : $APK_PATH ($(du -sh "$APK_PATH" | cut -f1))"
echo " AAB : $AAB_PATH ($(du -sh "$AAB_PATH" | cut -f1))"
echo " 보존: $DIST_DIR (산출물별 mapping·R8 출력·인증서·SHA-256·build-meta.json)"
