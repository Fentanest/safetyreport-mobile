#!/usr/bin/env bash
# 로컬 테스트용 APK 빌드 스크립트
# 기본: debug APK (서명 불필요)
# --release 옵션: 릴리즈 APK (외부 key.properties/keystore 필요)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/build_android_common.sh"

MODE="debug"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
KEY_PROPERTIES_PATH="${KEY_PROPERTIES_PATH:-$HOME/mysafetyreport-android/key.properties}"
KEYSTORE_PATH="${KEYSTORE_PATH:-$HOME/mysafetyreport-android/upload-keystore.jks}"

for arg in "$@"; do
    case "$arg" in
        --release) MODE="release" ;;
        --help|-h)
            echo "Usage: $0 [--release]"
            echo "  (기본) debug APK — 서명 불필요, 빠름"
            echo "  --release       — 릴리즈 APK (key.properties/keystore 필요)"
            echo ""
            echo "Optional environment variables:"
            echo "  FLUTTER_BIN         Flutter executable to use"
            echo "  KEY_PROPERTIES_PATH Local path to key.properties"
            echo "  KEYSTORE_PATH       Local path to upload-keystore.jks"
            exit 0
            ;;
    esac
done

ensure_flutter_available "$FLUTTER_BIN"

# VERSION 읽기
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
BUILD_NAME="${VERSION%%+*}"
BUILD_NUMBER="${VERSION##*+}"

if [[ -z "$BUILD_NAME" || -z "$BUILD_NUMBER" || "$BUILD_NAME" == "$BUILD_NUMBER" ]]; then
    echo "❌ VERSION 형식이 올바르지 않습니다. 기대 형식: 1.2.3+45" >&2
    exit 1
fi

echo "=========================================="
echo " 빌드 모드  : $MODE"
echo " 버전       : $BUILD_NAME+$BUILD_NUMBER"
echo " Flutter bin: $FLUTTER_BIN"
echo "=========================================="

# pubspec.yaml 버전 동기화
sync_pubspec_version "$SCRIPT_DIR" "$VERSION"

if [[ "$MODE" == "release" ]]; then
    KEY_PROPERTIES_PATH="$(resolve_abs_path "$KEY_PROPERTIES_PATH")"
    KEYSTORE_PATH="$(resolve_abs_path "$KEYSTORE_PATH")"

    if [[ ! -f "$KEY_PROPERTIES_PATH" || ! -f "$KEYSTORE_PATH" ]]; then
        echo "❌ 키스토어 파일 없음: $KEY_PROPERTIES_PATH 또는 $KEYSTORE_PATH" >&2
        exit 1
    fi

    trap cleanup_android_signing_files EXIT
    stage_android_signing_files "$SCRIPT_DIR" "$KEY_PROPERTIES_PATH" "$KEYSTORE_PATH"
    echo "✅ android/key.properties staged for local Flutter build"

    APK_SRC="build/app/outputs/flutter-apk/app-release.apk"
    APK_DEST="$SCRIPT_DIR/mysafetyreport-release.apk"
else
    APK_SRC="build/app/outputs/flutter-apk/app-debug.apk"
    APK_DEST="$SCRIPT_DIR/mysafetyreport-debug.apk"
fi

"$FLUTTER_BIN" --version
"$FLUTTER_BIN" pub get

if [[ "$MODE" == "release" ]]; then
    "$FLUTTER_BIN" build apk --release \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER"
else
    "$FLUTTER_BIN" build apk --debug \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER"
fi

cp "$SCRIPT_DIR/$APK_SRC" "$APK_DEST"

echo ""
echo "✅ 완료: $APK_DEST"
echo "   크기: $(du -sh "$APK_DEST" | cut -f1)"
