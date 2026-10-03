#!/usr/bin/env python3
"""Offline profile probe navigation. Disposable emulator + fixture package ONLY.
Run after SR_PROBE complete. No crawler/rating/upload controls are touched.
"""
import argparse, json, re, subprocess, time, xml.etree.ElementTree as ET
p=argparse.ArgumentParser()
p.add_argument('--adb',required=True)
p.add_argument('--serial',default='emulator-5580')
p.add_argument('--application-id',default='com.fentanest.mysafetyreport.fixture2')
p.add_argument('--cycles',type=int,default=20)
p.add_argument('--wait-data',action='store_true',help='Require full population data and charts, not just navigation controls')
p.add_argument('--expected-total',default='499000')
a=p.parse_args()
assert a.serial.startswith('emulator-') and '.fixture' in a.application_id

def adb(*args):
 return subprocess.check_output([a.adb,'-s',a.serial,*args],timeout=30).decode(errors='replace')
def nodes():
 result=adb('shell','uiautomator','dump','/sdcard/sr_fixture_ui.xml')
 if 'dumped to' not in result: raise RuntimeError('UiAutomator returned no root; retry capture')
 return list(ET.fromstring(adb('shell','cat','/sdcard/sr_fixture_ui.xml')).iter('node'))
def tap(label):
 for attempt in range(6):
  try:
   for n in nodes():
    if (n.get('text')==label or n.get('content-desc')==label) and n.get('clickable')=='true':
     x1,y1,x2,y2=map(int,re.findall(r'\d+',n.get('bounds')))
     adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2));return
  except (RuntimeError,subprocess.TimeoutExpired,subprocess.CalledProcessError): pass
  time.sleep(.5)
 raise RuntimeError('Fixture action missing: '+label)
def wait_content(label,timeout=180,exact=False):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  try:
   if any(((label in (n.get('text',''),n.get('content-desc','')) or n.get('content-desc','').splitlines()==['전체',label]) if exact else label in (n.get('text','')+n.get('content-desc',''))) for n in nodes()): return
  except (RuntimeError,subprocess.TimeoutExpired,subprocess.CalledProcessError): pass
  time.sleep(.3)
 raise RuntimeError('Data never became ready: '+label)
for permission in ['android.permission.ACCESS_FINE_LOCATION','android.permission.ACCESS_COARSE_LOCATION']:
 adb('shell','pm','grant',a.application_id,permission)
started=time.monotonic()
for i in range(a.cycles):
 tap('대시보드');time.sleep(.25)
 if a.wait_data: wait_content(a.expected_total+'건',exact=True)
 tap('통계');time.sleep(.25)
 if a.wait_data: wait_content('월별 처리 추이')
 tap('지도');time.sleep(.5)
 if a.wait_data: wait_content('좌표화')
 xml=nodes()
 assert any('신고 지도' in (n.get('text','')+n.get('content-desc','')) for n in xml), 'Map navigation failed'
 adb('shell','input','keyevent','4');time.sleep(.25)
 assert '합성 자료 검증' in adb('shell','cat','/sdcard/sr_fixture_ui.xml') or adb('shell','pidof',a.application_id).strip()
 print(json.dumps({'stage':'actual_navigation','cycle':i+1,'data_ready_required':a.wait_data,'elapsed_s':round(time.monotonic()-started,2)}),flush=True)
adb('shell','input','keyevent','3');time.sleep(1)
adb('shell','am','start','-n',a.application_id+'/com.fentanest.mysafetyreport.MainActivity')
print(json.dumps({'stage':'background_resume','completed_cycles':a.cycles}),flush=True)
