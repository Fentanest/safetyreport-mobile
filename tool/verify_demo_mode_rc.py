#!/usr/bin/env python3
"""Real lib/main.dart debug APK smoke check, confined to emulator-5580/demorc."""
from pathlib import Path
import argparse
import json
import signal
import re
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs/implementation/demo-mode-bypass-20261007/evidence'
ADB = [str(Path.home() / 'Android/Sdk/platform-tools/adb'), '-s', 'emulator-5580']
APP = 'com.fentanest.mysafetyreport.demorc'

def adb(*args):
    return subprocess.check_output([*ADB, *args], timeout=30)

def ui():
    for _ in range(5):
        result = adb('shell', 'uiautomator', 'dump', '/sdcard/demo-window.xml')
        if b'dumped to' in result:
            return adb('exec-out', 'cat', '/sdcard/demo-window.xml')
        time.sleep(1)
    raise RuntimeError('UI hierarchy unavailable')

def nodes(raw):
    return list(ET.fromstring(raw).iter('node'))

def label(n):
    return n.get('text', '') + n.get('content-desc', '')

def tap_node(n):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds')))
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
    time.sleep(0.6)

def tap_text(text):
    raw = ui()
    matches = [n for n in nodes(raw) if text in label(n)]
    if not matches:
        raise AssertionError(f'Missing {text}: ' + str([label(n) for n in nodes(raw) if label(n)]))
    tap_node(matches[0])

def capture(name, required=None):
    raw = ui()
    labels = '\n'.join(label(n) for n in nodes(raw))
    assert '카카오' not in labels and '클라우드' not in labels, labels
    if required:
        assert required in labels, labels
    (OUT / f'{name}.xml').write_bytes(raw)
    (OUT / f'{name}.png').write_bytes(adb('exec-out', 'screencap', '-p'))
    print('PASS capture ' + name, flush=True)
    return labels

def network(enabled):
    value = 'enable' if enabled else 'disable'
    adb('shell', 'svc', 'wifi', value)
    adb('shell', 'svc', 'data', value)
    time.sleep(2)

def fresh():
    assert adb('shell', 'pm', 'clear', APP).strip() == b'Success'
    adb('shell', 'am', 'start', '-n', APP+'/com.fentanest.mysafetyreport.MainActivity')
    for _ in range(12):
        if 'Standalone 모드' in ui().decode():
            return
        time.sleep(1)
    raise AssertionError('Mode selector did not open')

def services(name):
    raw = adb('shell', 'dumpsys', 'activity', 'services', APP).decode()
    (OUT / f'{name}-services.txt').write_text(raw)
    for forbidden in ['WsService', 'SyncForegroundService', 'LoginKeepAliveService']:
        assert forbidden not in raw, raw
    # Geolocator plugin binds a local, non-foreground service when the engine starts.
    assert 'isForeground=true' not in raw, raw

def logs(name):
    pid = adb('shell', 'pidof', APP).decode().strip().split()[0]
    raw = adb('logcat', '-d', '--pid='+pid, '-v', 'threadtime').decode(errors='replace')
    raw = '\n'.join(line for line in raw.splitlines()
                    if not any(s in line for s in ['VM service', 'Dart VM', 'Observatory', '127.0.0.1:']))
    (OUT / f'{name}-logcat.txt').write_text(raw+'\n')
    assert not re.search(r'FATAL EXCEPTION|Unhandled Exception|EXCEPTION CAUGHT|E/flutter', raw), raw
    errors = [line for line in raw.splitlines() if re.search(r' [EF] ', line)]
    journal_locks = [line for line in errors
                     if 'E SQLiteLog:' in line and 'journal_mode=TRUNCATE' in line
                     and 'database is locked' in line]
    assert len(errors) == len(journal_locks), errors
    if journal_locks:
        print(f'WARN {name}: SQLite journal-mode lock entries={len(journal_locks)}; '
              'verify DB integrity separately', flush=True)

def login_case(name, phone=''):
    fresh()
    capture(name+'-01-mode', 'Standalone 모드')
    tap_text('Standalone 모드')
    for index, value in enumerate(['demo', 'demo', phone]):
        if not value:
            continue
        fields = [n for n in nodes(ui()) if n.get('class') == 'android.widget.EditText']
        assert len(fields) == 3
        tap_node(fields[index])
        adb('shell', 'input', 'text', value)
        adb('shell', 'input', 'keyevent', '4')
        time.sleep(0.4)
    capture(name+'-02-review-login', 'demo')
    # Use the exact button; the page heading also contains 로그인.
    for n in nodes(ui()):
        if label(n) == '로그인' and n.get('class') == 'android.widget.Button':
            tap_node(n)
            break
    for _ in range(10):
        if '대시보드' in ui().decode():
            break
        time.sleep(1)
    capture(name+'-03-dashboard', '대시보드')

def tabs_case(name):
    for i, tab in enumerate(['신고내역', '신고관리', '통계', '알림'], 4):
        tap_text(tab)
        capture(f'{name}-{i:02d}-tab', tab)
    services(name)
    logs(name)
    adb('shell', 'am', 'force-stop', APP)
    adb('shell', 'am', 'start', '-n', APP+'/com.fentanest.mysafetyreport.MainActivity')
    time.sleep(3)
    capture(name+'-08-relaunch', '대시보드')
    logs(name+'-relaunch')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['login', 'tabs', 'button'])
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    avd = adb('shell', 'getprop', 'ro.boot.qemu.avd_name').decode().strip()
    assert avd == 'sr_uitest_api35', avd
    # Ensure network restoration even when the execution runner sends SIGTERM.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    name = 'offline' if args.offline else 'online'
    try:
        network(not args.offline)
        if args.offline:
            (OUT / 'offline-network.txt').write_text(
                adb('shell', 'settings', 'get', 'global', 'wifi_on').decode() +
                adb('shell', 'settings', 'get', 'global', 'mobile_data').decode() +
                adb('shell', 'dumpsys', 'connectivity').decode())
        if args.stage == 'login':
            login_case(name, phone='demo' if args.offline else '')
        elif args.stage == 'tabs':
            tabs_case(name)
        else:
            fresh()
            tap_text('Demo 보기')
            time.sleep(2)
            capture(name+'-09-demo-button', '대시보드')
            logs(name+'-demo-button')
    finally:
        network(True)
        restored = {
            key: adb('shell', 'settings', 'get', 'global', key).decode().strip()
            for key in ['wifi_on', 'mobile_data']
        }
        (OUT / 'network-restored.json').write_text(json.dumps(restored, indent=2)+'\n')
        print('Network restored: '+str(restored), flush=True)
