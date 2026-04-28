#!/usr/bin/env bash
set -euo pipefail

# build-apk.yml 과 동일한 방식으로 로컬에서 Android release APK/AAB 를 빌드한다.
#
# 기본 동작:
# - VERSION 읽기
# - pubspec.yaml version 동기화
# - Flutter Docker 이미지에서 release APK + AAB 빌드
# - 산출물을 workflow 와 동일한 이름으로 복사
#
# 환경변수로 경로/이미지를 덮어쓸 수 있다.
#   FLUTTER_IMAGE
#   KEY_PROPERTIES_PATH
#   KEYSTORE_PATH
#   PUB_CACHE_DIR
#   ANDROID_NDK_CACHE_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
KEY_PROPERTIES_PATH="${KEY_PROPERTIES_PATH:-$HOME/mysafetyreport-android/key.properties}"
KEYSTORE_PATH="${KEYSTORE_PATH:-$HOME/mysafetyreport-android/upload-keystore.jks}"
PUB_CACHE_DIR="${PUB_CACHE_DIR:-$HOME/.pub-cache}"
ANDROID_NDK_CACHE_DIR="${ANDROID_NDK_CACHE_DIR:-$HOME/.android-ndk-cache}"

usage() {
  cat <<'EOF'
Usage: ./build_android_release.sh

Build release APK and AAB locally using the same Docker-based flow as
.github/workflows/build-apk.yml.

Optional environment variables:
  FLUTTER_IMAGE         Docker image to use
  KEY_PROPERTIES_PATH   Local path to key.properties
  KEYSTORE_PATH         Local path to upload-keystore.jks
  PUB_CACHE_DIR         Local pub cache directory to mount
  ANDROID_NDK_CACHE_DIR Local Android NDK cache directory to mount
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

if ! command -v docker >/dev/null 2>&1; then
  echo "❌ docker 명령을 찾을 수 없습니다." >&2
  exit 1
fi

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

if [[ ! -f "$KEY_PROPERTIES_PATH" ]]; then
  echo "❌ key.properties 파일이 없습니다: $KEY_PROPERTIES_PATH" >&2
  exit 1
fi

if [[ ! -f "$KEYSTORE_PATH" ]]; then
  echo "❌ upload-keystore.jks 파일이 없습니다: $KEYSTORE_PATH" >&2
  exit 1
fi

mkdir -p "$PUB_CACHE_DIR" "$ANDROID_NDK_CACHE_DIR"

echo "=========================================="
echo " Android release build"
echo " Version      : $BUILD_NAME+$BUILD_NUMBER"
echo " Flutter image: $FLUTTER_IMAGE"
echo " Repo         : $SCRIPT_DIR"
echo "=========================================="

sed -i "s/^version:.*/version: $VERSION/" "$SCRIPT_DIR/pubspec.yaml"
echo "✅ pubspec.yaml version synced to $VERSION"

docker run --rm \
  -v "$SCRIPT_DIR":/build \
  -v "$PUB_CACHE_DIR":/root/.pub-cache \
  -v "$ANDROID_NDK_CACHE_DIR":/root/Android/Sdk/ndk \
  -v "$KEY_PROPERTIES_PATH":/build/android/key.properties:ro \
  -v "$KEYSTORE_PATH":/build/upload-keystore.jks:ro \
  --workdir /build \
  "$FLUTTER_IMAGE" \
  bash -lc "\
    flutter build apk --release \
      --build-name=$BUILD_NAME \
      --build-number=$BUILD_NUMBER && \
    flutter build appbundle --release \
      --build-name=$BUILD_NAME \
      --build-number=$BUILD_NUMBER && \
    cp build/app/outputs/flutter-apk/app-release.apk build/app/outputs/flutter-apk/mysafetyreport.apk && \
    cp build/app/outputs/bundle/release/app-release.aab build/app/outputs/bundle/release/mysafetyreport.aab"

sudo chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR" 2>/dev/null || true

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
