#!/usr/bin/env python3
"""Run the isolated RC test and capture actual Android frames with adb.
Only emulator-5580 and the bindingrc application ID are permitted.
"""
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / 'docs/implementation/official-account-binding-20261006/evidence'
ADB = [str(Path.home() / 'Android/Sdk/platform-tools/adb'), '-s', 'emulator-5580']
APP = 'com.fentanest.mysafetyreport.bindingrc'
FLUTTER = str(Path.home() / 'development/flutter-3.47.5/bin/flutter')

def adb(*args, **kwargs):
    return subprocess.run([*ADB, *args], check=True, **kwargs)

if adb('shell', 'getprop', 'sys.boot_completed', capture_output=True).stdout.strip() != b'1':
    raise SystemExit('Assigned emulator is not booted')
EVIDENCE.mkdir(parents=True, exist_ok=True)
# Clear only our synthetic test sandbox when repeating a failed test.
installed = adb('shell', 'pm', 'list', 'packages', APP, capture_output=True).stdout
if APP.encode() in installed:
    adb('shell', 'pm', 'clear', APP, stdout=subprocess.DEVNULL)
env = dict(os.environ, SR_TEST_APPLICATION_ID=APP,
           DASH__SUPPRESS_ANALYTICS='true', FLUTTER_SUPPRESS_ANALYTICS='true')
env['ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy'] = 'in-process'
if APP.encode() not in installed:
    subprocess.run([FLUTTER, 'build', 'apk', '--debug', '--no-pub'],
                   cwd=ROOT, env=env, check=True)
    adb('install', '-r', str(ROOT / 'build/app/outputs/flutter-apk/app-debug.apk'))
# Android kills a running process when this app-op changes.
adb('shell', 'appops', 'set', APP, 'MANAGE_EXTERNAL_STORAGE', 'allow')
pid = ''
with (EVIDENCE / 'integration-test.log').open('w') as log:
    proc = subprocess.Popen([FLUTTER, 'test', '--no-pub', '-d', 'emulator-5580',
        'integration_test/official_binding_rc_test.dart', '--reporter', 'expanded'],
        cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1)
    for line in proc.stdout:
        log.write(line)
        log.flush()
        match = re.search(r'SR_CAPTURE:([a-z0-9-]+)', line)
        if not match:
            continue
        name = match.group(1)
        pid = adb('shell', 'pidof', APP, capture_output=True).stdout.decode().strip()
        if name.endswith('-back'):
            adb('shell', 'input', 'keyevent', '4')
            time.sleep(0.8)
        focus = adb('shell', 'dumpsys', 'window', capture_output=True).stdout.decode()
        if not any(APP in line for line in focus.splitlines() if 'mCurrentFocus' in line):
            proc.terminate()
            raise RuntimeError('Test application lost foreground: ' + name)
        with (EVIDENCE / f'{name}.png').open('wb') as screenshot:
            adb('exec-out', 'screencap', '-p', stdout=screenshot)
        adb('shell', 'run-as', APP, 'touch', f'files/{name}.ack')
        print(f'Captured {name}', flush=True)
    code = proc.wait()
    log.write(f'\nEXIT_CODE={code}\n')
# Capture only the test process, avoiding unrelated apps and VM service URLs.
if pid:
    output = adb('logcat', '-d', '--pid=' + pid.split()[0], '-v', 'threadtime',
                 capture_output=True).stdout.decode(errors='replace')
    output = '\n'.join(line for line in output.splitlines()
                       if not any(s in line for s in ['VM service', 'Dart VM', '127.0.0.1:', 'Observatory']))
    (EVIDENCE / 'logcat.txt').write_text(output + '\n')
raise SystemExit(code)
