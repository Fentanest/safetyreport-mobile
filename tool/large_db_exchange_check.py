#!/usr/bin/env python3
"""Synthetic-only PC↔mobile exchange with native SQL comparisons, no all-row lists.
Uses the PC's real restore and mobile's real import harness. The PC repo is read
only; all databases and PC runtime data live in a new temporary directory.
Generate a realistic fixture with SR_EXCHANGE_FIXTURE_OUT=... and
test/tool/large_exchange_fixture_test.dart (or use the giant-group stress fixture).
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import time


def compare(before, after, table, keys, columns=None):
    con = sqlite3.connect(f'file:{before}?mode=ro', uri=True)
    try:
        con.execute('ATTACH DATABASE ? AS latter', (f'file:{after}?mode=ro',))
        names = [r[1] for r in con.execute(f'PRAGMA main.table_info("{table}")')]
        other = [r[1] for r in con.execute(f'PRAGMA latter.table_info("{table}")')]
        if set(names) != set(other):
            return {'schema_difference': True}
        columns = columns or names
        match = ' AND '.join(f'a."{k}" IS b."{k}"' for k in keys)
        missing = con.execute(f'SELECT COUNT(*) FROM main."{table}" a WHERE NOT EXISTS(SELECT 1 FROM latter."{table}" b WHERE {match})').fetchone()[0]
        extra = con.execute(f'SELECT COUNT(*) FROM latter."{table}" b WHERE NOT EXISTS(SELECT 1 FROM main."{table}" a WHERE {match})').fetchone()[0]
        expressions = ','.join(f'SUM(CASE WHEN a."{c}" IS NOT b."{c}" OR typeof(a."{c}")<>typeof(b."{c}") THEN 1 ELSE 0 END)' for c in columns)
        values = con.execute(f'SELECT {expressions} FROM main."{table}" a JOIN latter."{table}" b ON {match}').fetchone()
        return {'before': con.execute(f'SELECT COUNT(*) FROM main."{table}"').fetchone()[0],
                'after': con.execute(f'SELECT COUNT(*) FROM latter."{table}"').fetchone()[0],
                'missing': missing, 'extra': extra,
                'columns': {c: n for c, n in zip(columns, values) if n}}
    finally:
        con.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--pc-repo', type=Path, required=True)
    p.add_argument('--flutter', required=True)
    p.add_argument('--count', type=int, default=500000)
    p.add_argument('--verify-work-dir', type=Path, help='Recheck completed synthetic exchange artifacts without restoring again')
    args = p.parse_args()
    mobile_repo = Path(__file__).resolve().parents[1]
    source = args.source.resolve()
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as con:
        assert con.execute('SELECT COUNT(*) FROM reports').fetchone()[0] == args.count
        assert con.execute("SELECT COUNT(*) FROM reports WHERE ID NOT LIKE 'fixture-%'").fetchone()[0] == 0, 'Synthetic fixture only'
        assert con.execute("SELECT value FROM sync_meta WHERE key='kakao_member_id'").fetchone()[0] == '910001'
    spec = importlib.util.spec_from_file_location('pc_roundtrip', args.pc_repo / 'scripts/dev/db_roundtrip_check.py')
    pc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pc)
    work = args.verify_work_dir.resolve() if args.verify_work_dir else Path(tempfile.mkdtemp(prefix='sr_exchange_large_'))
    if args.verify_work_dir:
        assert work.name.startswith('sr_exchange_large_') and work.parent == Path(tempfile.gettempdir())
    def stage(name, action):
        timer = time.monotonic()
        result = action()
        print(json.dumps({'stage': name, 'seconds': round(time.monotonic()-timer, 3)}, ensure_ascii=False), flush=True)
        return result
    if args.verify_work_dir:
        s0, m1, s2, m3 = work/'s0'/'data.db', work/'m1.db', work/'s2'/'data.db', work/'m3.db'
        for path in [s0, m1, s2, m3]:
            assert path.is_file(), path
    else:
        s0 = stage('M0_to_S0_real_PC_restore', lambda: pc.restore_mobile_into_server(source, work/'s0'))
        m1 = stage('S0_to_M1_real_mobile_import', lambda: pc.mobile_import(s0, work/'m1.db', mobile_repo, args.flutter))
        s2 = stage('M1_to_S2_real_PC_restore', lambda: pc.restore_mobile_into_server(m1, work/'s2'))
        m3 = stage('S2_to_M3_real_mobile_import', lambda: pc.mobile_import(s2, work/'m3.db', mobile_repo, args.flutter))
    results = {}
    server_keys = {'mysafety_entry_value': ['ID'], 'mysafety_raw_content': ['ID'],
                   'mysafety_watchlist': ['신고번호'], 'mysafety_sync_meta': ['key'],
                   'mysafety_geocode_cache': ['주소정규화'], 'mysafety_report_override': ['ID', 'column_name'],
                   'mysafety_duplicate_decision': ['group_id'], 'mysafety_duplicate_group': ['group_id'],
                   'mysafety_duplicate_member': ['group_id', 'report_id']}
    for t in pc.SERVER_TABLES_BY_ID:
        server_keys.setdefault(t, ['ID'])
    # map_backfill_state is the PC runtime's own meta, explicitly excluded by
    # the canonical small roundtrip harness as well. Remove it in test copies.
    for path in [s0, s2]:
        with sqlite3.connect(path) as con:
            con.execute("DELETE FROM mysafety_sync_meta WHERE key='map_backfill_state'")
    for table, keys in server_keys.items():
        results['A:'+table] = stage('compare_A:'+table, lambda t=table,k=keys: compare(s0,s2,t,k))
    mobile_keys = {'reports':['ID'], 'report_raw':['ID'], 'sync_meta':['key'],
                   'geocode_cache':['주소정규화'], 'report_override':['ID','column_name'],
                   'duplicate_decision':['group_id'], 'duplicate_group':['group_id'],
                   'duplicate_member':['group_id','report_id']}
    for table, keys in mobile_keys.items():
        results['B:'+table] = stage('compare_B:'+table, lambda t=table,k=keys: compare(m1,m3,t,k))
    contract = json.loads((mobile_repo/'contracts/storage-contract.json').read_text())
    report = next(e for e in contract['entities'] if e['entity']=='report')
    columns = [c['name'] for c in report['columns'] if c.get('exchange') and c.get('mobile')]
    results['initial_exchange_reports'] = stage('compare_M0_to_M1_exchange_columns', lambda: compare(source,m1,'reports',['ID'],columns))
    for table, keys in mobile_keys.items():
        if table not in ['reports','sync_meta']:
            results['initial_exchange_'+table] = compare(source,m1,table,keys)
    contracts = {}
    for name in ['storage-contract.json','parser-vectors.json','exif-vectors.json','rating-eligibility-vectors.json','dark-palette.json','selfhost-compat/README.md','selfhost-compat/vectors.json']:
        left=(mobile_repo/'contracts'/name).read_bytes()
        right=(args.pc_repo/'contracts'/name).read_bytes()
        contracts[name] = hashlib.sha256(left).hexdigest() == hashlib.sha256(right).hexdigest()
    differences = sum(r.get('missing',0)+r.get('extra',0)+sum(r.get('columns',{}).values())+int(r.get('schema_difference',False)) for r in results.values())
    differences += sum(not v for v in contracts.values())
    assert results['B:reports']['before']==results['B:reports']['after']==args.count
    summary = {'kind':'synthetic_host_exchange_not_device_performance','rows':args.count,'diff_count':differences,
               'results':results,'contracts_identical':contracts,'work_dir':str(work)}
    print(json.dumps(summary,ensure_ascii=False,indent=2),flush=True)
    return 1 if differences else 0

if __name__=='__main__':
    raise SystemExit(main())
