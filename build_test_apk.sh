#!/bin/bash
# 로컬 테스트용 APK 빌드 스크립트
# 기본: debug APK (서명 불필요)
# --release 옵션: 릴리즈 APK (~/mysafetyreport-android/ 키스토어 필요)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="debug"
FLUTTER_IMAGE="ghcr.io/cirruslabs/flutter:stable"

for arg in "$@"; do
    case "$arg" in
        --release) MODE="release" ;;
        --help|-h)
            echo "Usage: $0 [--release]"
            echo "  (기본) debug APK — 서명 불필요, 빠름"
            echo "  --release       — 릴리즈 APK (~/mysafetyreport-android/ 키스토어 필요)"
            exit 0
            ;;
    esac
done

# VERSION 읽기
VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
BUILD_NAME=$(echo "$VERSION" | cut -d'+' -f1)
BUILD_NUMBER=$(echo "$VERSION" | cut -d'+' -f2)

echo "=========================================="
echo " 빌드 모드  : $MODE"
echo " 버전       : $BUILD_NAME+$BUILD_NUMBER"
echo "=========================================="

# pubspec.yaml 버전 동기화
sed -i "s/^version:.*/version: $VERSION/" "$SCRIPT_DIR/pubspec.yaml"

# Docker 마운트 옵션 구성
DOCKER_OPTS=(
    --rm
    -v "$SCRIPT_DIR":/build
    -v "$HOME/.pub-cache":/root/.pub-cache
    --workdir /build
)

if [ "$MODE" = "release" ]; then
    KEY_PROPS="$HOME/mysafetyreport-android/key.properties"
    KEYSTORE="$HOME/mysafetyreport-android/upload-keystore.jks"
    if [ ! -f "$KEY_PROPS" ] || [ ! -f "$KEYSTORE" ]; then
        echo "❌ 키스토어 파일 없음: $KEY_PROPS 또는 $KEYSTORE"
        exit 1
    fi
    DOCKER_OPTS+=(
        -v "$KEY_PROPS":/build/android/key.properties:ro
        -v "$KEYSTORE":/build/upload-keystore.jks:ro
    )
    BUILD_CMD="flutter build apk --release --build-name=$BUILD_NAME --build-number=$BUILD_NUMBER"
    APK_SRC="build/app/outputs/flutter-apk/app-release.apk"
    APK_DEST="$SCRIPT_DIR/mysafetyreport-release.apk"
else
    BUILD_CMD="flutter build apk --debug --build-name=$BUILD_NAME --build-number=$BUILD_NUMBER"
    APK_SRC="build/app/outputs/flutter-apk/app-debug.apk"
    APK_DEST="$SCRIPT_DIR/mysafetyreport-debug.apk"
fi

docker run "${DOCKER_OPTS[@]}" "$FLUTTER_IMAGE" bash -c "$BUILD_CMD"

# Docker가 생성한 파일 소유권 복구
sudo chown -R "$(id -u):$(id -g)" "$SCRIPT_DIR/build" 2>/dev/null || true

cp "$SCRIPT_DIR/$APK_SRC" "$APK_DEST"

echo ""
echo "✅ 완료: $APK_DEST"
echo "   크기: $(du -sh "$APK_DEST" | cut -f1)"
