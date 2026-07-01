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
