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
