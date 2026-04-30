#!/usr/bin/env bash
set -euo pipefail

# build-apk.yml 과 동일한 방식으로 로컬에서 Android release APK/AAB 를 빌드한다.
#
# 기본 동작:
# - VERSION 읽기
# - pubspec.yaml version 동기화
# - 외부 key.properties 를 android/key.properties 로 임시 배치
# - key.properties 의 storeFile 을 현재 키스토어 절대경로로 교정
# - 로컬 Flutter CLI 에서 release APK + AAB 빌드
# - 산출물을 workflow 와 동일한 이름으로 복사
#
# 환경변수로 명령/경로를 덮어쓸 수 있다.
#   FLUTTER_BIN
#   KEY_PROPERTIES_PATH
#   KEYSTORE_PATH

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

ensure_flutter_available "$FLUTTER_BIN"

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

trap cleanup_android_signing_files EXIT

echo "=========================================="
echo " Android release build"
echo " Version      : $BUILD_NAME+$BUILD_NUMBER"
echo " Flutter bin  : $FLUTTER_BIN"
echo " Repo         : $SCRIPT_DIR"
echo "=========================================="

sync_pubspec_version "$SCRIPT_DIR" "$VERSION"
stage_android_signing_files "$SCRIPT_DIR" "$KEY_PROPERTIES_PATH" "$KEYSTORE_PATH"
echo "✅ android/key.properties staged for local Flutter build"

"$FLUTTER_BIN" --version
"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" build apk --release \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER"
"$FLUTTER_BIN" build appbundle --release \
  --build-name="$BUILD_NAME" \
  --build-number="$BUILD_NUMBER"

cp "$SCRIPT_DIR/build/app/outputs/flutter-apk/app-release.apk" \
  "$SCRIPT_DIR/build/app/outputs/flutter-apk/mysafetyreport.apk"
cp "$SCRIPT_DIR/build/app/outputs/bundle/release/app-release.aab" \
  "$SCRIPT_DIR/build/app/outputs/bundle/release/mysafetyreport.aab"

APK_PATH="$SCRIPT_DIR/build/app/outputs/flutter-apk/mysafetyreport.apk"
AAB_PATH="$SCRIPT_DIR/build/app/outputs/bundle/release/mysafetyreport.aab"

if [[ ! -f "$APK_PATH" ]]; then
  echo "❌ APK 산출물을 찾을 수 없습니다: $APK_PATH" >&2
  exit 1
fi

if [[ ! -f "$AAB_PATH" ]]; then
  echo "❌ AAB 산출물을 찾을 수 없습니다: $AAB_PATH" >&2
  exit 1
fi

echo
echo "✅ 완료"
echo " APK: $APK_PATH"
echo " AAB: $AAB_PATH"
echo " APK size: $(du -sh "$APK_PATH" | cut -f1)"
echo " AAB size: $(du -sh "$AAB_PATH" | cut -f1)"
