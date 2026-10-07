#!/usr/bin/env python3
"""Capture real Android frames and service state for the isolated hotfix fixture."""
import argparse
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP = 'com.fentanest.mysafetyreport.offlineqa'
parser = argparse.ArgumentParser()
parser.add_argument('--device', default='emulator-5564')
args = parser.parse_args()
if not re.fullmatch(r'emulator-\d+', args.device):
    raise SystemExit('Only a test emulator is permitted')
ADB = [str(Path.home() / 'Android/Sdk/platform-tools/adb'), '-s', args.device]
FLUTTER = os.environ['SR_QA_FLUTTER']
EVIDENCE = ROOT / 'docs/reviews/evidence/2026-10-07-emergency-offline'

def adb(*arguments, **kwargs):
    return subprocess.run([*ADB, *arguments], check=True, **kwargs)

if adb('emu', 'avd', 'name', capture_output=True).stdout.splitlines()[0] != b'sr_offline_20261007':
    raise SystemExit('Only sr_offline_20261007 is permitted')
EVIDENCE.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, SR_TEST_APPLICATION_ID=APP)
env['ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy'] = 'in-process'
passed = False
with (EVIDENCE / 'integration.log').open('w') as log:
    proc = subprocess.Popen([
        FLUTTER, 'test', '--no-pub', '-d', args.device,
        'integration_test/emergency_offline_test.dart', '--reporter', 'expanded',
    ], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1)
    try:
        for line in proc.stdout:
            log.write(line)
            log.flush()
            passed |= 'SR_ASSERT:OFFLINE_SCENARIOS_PASS' in line
            match = re.search(r'SR_CAPTURE:([a-z0-9-]+)', line)
            if not match:
                continue
            name = match[1]
            if name.startswith('01-'):
                adb('shell', 'pm', 'grant', APP, 'android.permission.POST_NOTIFICATIONS')
            with (EVIDENCE / f'{name}.png').open('wb') as screenshot:
                adb('exec-out', 'screencap', '-p', stdout=screenshot)
            if name.startswith(('04-', '05-', '06-')):
                services = adb('shell', 'dumpsys', 'activity', 'services', APP,
                               capture_output=True).stdout.decode()
                # dumpsys includes an unrelated last-ANR block even with a package filter.
                active_start = services.find('  User 0 active services:')
                services = services[active_start:] if active_start >= 0 else 'No active test services\n'
                notifications = adb('shell', 'dumpsys', 'notification',
                                    capture_output=True).stdout.decode()
                active = [line for line in notifications.splitlines()
                          if 'NotificationRecord(' in line and APP in line]
                (EVIDENCE / f'{name}.txt').write_text(
                    services + '\nACTIVE_TEST_NOTIFICATIONS\n' + '\n'.join(active))
                if name.startswith('04-'):
                    if 'WsService' not in services:
                        raise RuntimeError('Service never started')
                    if not any('id=1001' in line for line in active):
                        raise RuntimeError('Initial foreground notification missing')
                else:
                    if 'ServiceRecord{' in services and 'WsService' in services:
                        raise RuntimeError('WebSocket service still running')
                    if any('id=1001' in line for line in active):
                        raise RuntimeError('WebSocket notification still present')
            adb('shell', 'run-as', APP, 'touch', f'files/{name}.ack')
            print(f'Captured {name}', flush=True)
        code = proc.wait()
        log.write(f'\nEXIT_CODE={code}\nSCENARIOS_PASSED={passed}\n')
    finally:
        if proc.poll() is None:
            proc.terminate()
if code or not passed:
    raise SystemExit(code or 1)
