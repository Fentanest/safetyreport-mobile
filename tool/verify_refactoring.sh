#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pin=$(tr -d '[:space:]' < tool/flutter-version)
flutter_cli=${FLUTTER_BIN:-"$HOME/development/flutter-$pin/bin/flutter"}
actual=$("$flutter_cli" --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')
[[ "$actual" == "$pin" ]] || { echo "Flutter mismatch: expected $pin, received $actual" >&2; exit 1; }
verify_root=$(mktemp -d -t sr-verification-XXXXXXXX)
verification_props_hash=""
original_props=false
created_wrappers=()
cleanup() {
  if [[ -n "$verification_props_hash" && -f android/local.properties && "$(sha256sum android/local.properties | cut -d' ' -f1)" == "$verification_props_hash" ]]; then
    if [[ "$original_props" == true ]]; then cp "$verify_root/local.properties" android/local.properties; else rm -- android/local.properties; fi
  fi
  for file in "${created_wrappers[@]}"; do rm -- "$file"; done
  rm -rf -- "$verify_root"
}
trap cleanup EXIT
"$flutter_cli" pub get --enforce-lockfile
analyze_exit=0
"$flutter_cli" analyze > "$verify_root/analyze.log" 2>&1 || analyze_exit=$?
cat "$verify_root/analyze.log"
python3 - "$verify_root/analyze.log" "$analyze_exit" <<'PY'
import collections, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
issues = re.findall(r'^\s*(error|warning) • .*? • ([^:]+):\d+:\d+ • (\S+)', text, re.M)
actual = collections.Counter((severity, path, code) for severity, path, code in issues)
allowed = collections.Counter({
    ('warning', 'test/storage/agency_registry_wiring_test.dart', 'unnecessary_cast'): 6,
    ('warning', 'test/storage/registry_vectors_test.dart', 'unnecessary_cast'): 3,
})
if actual - allowed or ('issues found.' not in text and 'No issues found!' not in text):
    raise SystemExit('Analysis failed or introduced a new error/warning')
if int(sys.argv[2]) not in (0, 1):
    raise SystemExit('Analyzer process failed')
PY
"$flutter_cli" test --no-pub
# Gradle's settings read flutter.sdk from an ignored local file. Temporarily
# point it at the same pinned SDK used above, and restore the original bytes.
flutter_sdk=$(dirname "$(dirname "$(readlink -f "$flutter_cli")")")
if [[ -f android/local.properties ]]; then
  cp android/local.properties "$verify_root/local.properties"
  original_props=true
fi
python3 - "$flutter_sdk" <<'PYSDK'
import os, pathlib, re, sys
props = pathlib.Path('android/local.properties')
text = props.read_text() if props.exists() else ''
text = re.sub(r'^flutter\.sdk=.*(?:\n|$)', '', text, flags=re.M)
sdk = pathlib.Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or str(pathlib.Path.home() / 'Android/Sdk'))
if not re.search(r'^sdk\.dir=', text, re.M):
    if not sdk.is_dir(): raise SystemExit('Android SDK directory unavailable')
    text += '\nsdk.dir=' + str(sdk) + '\n'
text += '\nflutter.sdk=' + sys.argv[1] + '\n'
props.write_text(text)
PYSDK
verification_props_hash=$(sha256sum android/local.properties | cut -d' ' -f1)
for relative in gradlew gradle/wrapper/gradle-wrapper.jar; do
  if [[ ! -f "android/$relative" ]]; then
    mkdir -p "$(dirname "android/$relative")"
    cp "$flutter_sdk/bin/cache/artifacts/gradle_wrapper/$relative" "android/$relative"
    created_wrappers+=("android/$relative")
  fi
done
# Unit and lint tasks only. This verification has no signing/packaging/release task.
if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME:-}/bin/javac" ]] && [[ -x "$HOME/development/android-studio/jbr/bin/javac" ]]; then
  export JAVA_HOME="$HOME/development/android-studio/jbr"
fi
bash android/gradlew -p android :app:testDebugUnitTest :app:lintDebug \
  -x :app:compileFlutterBuildDebug -x :app:mergeDebugAssets
