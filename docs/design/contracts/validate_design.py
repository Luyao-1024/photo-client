#!/usr/bin/env python3
"""Validate design documents and disposable SQLite fixtures; not application tests."""
from pathlib import Path
import sqlite3,json,re,argparse,copy
ROOT=Path(__file__).resolve().parents[3]
DESIGN=ROOT/'docs/design'
checks=[]
def passed(name):
 checks.append(name)
 print('PASS',name)
def expect_rejected(c,sql,params=()):
 c.execute('SAVEPOINT rejected')
 try:
  c.execute(sql,params)
 except sqlite3.IntegrityError:
  c.execute('ROLLBACK TO rejected');c.execute('RELEASE rejected');return
 c.execute('ROLLBACK TO rejected');c.execute('RELEASE rejected')
 raise AssertionError('expected constraint failure: '+sql)
def insert(c,table,**values):
 cols=','.join(values);marks=','.join('?' for _ in values)
 c.execute(f'INSERT INTO {table}({cols}) VALUES({marks})',tuple(values.values()))

manifest=json.loads((DESIGN/'contracts/design-manifest.json').read_text())
mods=manifest['modules']; assert len(mods)==17
allids=[]
for m in mods:
 text=(DESIGN/m['path']).read_text()
 for section in ['职责与范围','接口与数据','流程与状态','异常与恢复','验收']:
  assert f'## {section}' in text,(m['id'],section)
 ids=re.findall(r'^- (T\d{2}-\d{2})：',text,re.M)
 assert ids==m['tests'],m['id'];allids+=ids
 assert m['implementation_status'] in ('not_started','in_progress','implemented','verified')
assert len(allids)==len(set(allids))==79
matrix=(DESIGN/'acceptance.md').read_text()
assert sorted(re.findall(r'^\| (T\d{2}-\d{2}) \|',matrix,re.M))==sorted(allids)
passed('17 module contracts and 79 unique planned acceptance IDs')
known={m['id'] for m in mods};graph={m['id']:m['depends_on'] for m in mods}
seen=set();visiting=set()
def visit(mid):
 assert mid in known
 assert mid not in visiting,'cyclic module dependency'
 if mid in seen:return
 visiting.add(mid)
 for dep in graph[mid]:visit(dep)
 visiting.remove(mid);seen.add(mid)
for mid in graph:visit(mid)
for req,owners in manifest['requirements'].items():assert set(owners)<=known
passed('dependency DAG and requirement ownership')


plan=json.loads((DESIGN/manifest['delivery_plan']).read_text())
handbook=(DESIGN/plan['acceptance_handbook']).read_text()
def check_stage_structure(value):
 expected=[f'S{i:02d}' for i in range(15)]
 assert value['stage_order']==expected
 assert [st['id'] for st in value['stages']]==expected
 assert value['baseline_checkpoint']=='S00'
 assert value['current_checkpoint'] in expected
 if value.get('next_checkpoint') is not None: assert value['next_checkpoint'] in expected[1:]
 lookup={st['id']:st for st in value['stages']}
 for i,st in enumerate(value['stages']):
  assert st['depends_on']==([] if i==0 else [expected[i-1]])
  assert set(st['modules'])<=known
  assert st['user_review'] in ('not_applicable','not_recorded','pending_review','accepted','changes_requested')
  if i==0:
   assert st['gate_status']=='passed_design_only' and st['evidence_scope']=='design_only'
   assert not st['primary_tests']
  else:
   assert st['implementation_status'] in ('not_started','in_progress','implemented')
   assert st['gate_status'] in ('not_run','running','passed','failed','blocked','needs_retest')
   assert st['evidence_scope']=='application_stage'
   assert st['phase']==('L0' if i<=4 else 'L1' if i<=8 else 'L2' if i<=12 else 'L3')
   if st['gate_status']=='passed':
    assert lookup[expected[i-1]]['gate_status'] in ('passed','passed_design_only')
    assert st.get('build_id') and st.get('evidence_report')
    assert (DESIGN/st['evidence_report']).is_file()
 assert lookup['S14']['final_all_tests'] is True
 assert next(i for i,st in enumerate(value['stages']) if st['id']=='S04')<next(i for i,st in enumerate(value['stages']) if st['id']=='S05')
check_stage_structure(plan)
passed('S00 design baseline plus 14 ordered application gates and explicit result states')

def check_stage_ownership(value):
 declared=value['primary_test_owner'];actual={}
 for st in value['stages']:
  for tid in st['primary_tests']:
   assert tid in allids and tid not in actual
   assert 'M'+tid[1:3] in st['modules']
   actual[tid]=st['id']
 assert set(actual)==set(allids)
 assert declared==actual
check_stage_ownership(plan)
for corruption in ('missing_test','duplicate_test','forward_dependency','false_pass'):
 invalid=copy.deepcopy(plan)
 if corruption=='missing_test': invalid['stages'][1]['primary_tests'].pop()
 if corruption=='duplicate_test': invalid['stages'][2]['primary_tests'].append(invalid['stages'][1]['primary_tests'][0])
 if corruption=='forward_dependency': invalid['stages'][4]['depends_on']=['S05']
 if corruption=='false_pass': invalid['stages'][2]['gate_status']='passed'
 try:
  check_stage_structure(invalid);check_stage_ownership(invalid)
 except AssertionError: pass
 else: raise AssertionError('invalid stage plan accepted: '+corruption)
passed('all 79 tests have one complete-stage owner; missing/duplicate/skip/unsupported pass rejected')

manual_ids=re.findall(r'\b(S\d{2}-C\d{2})：',handbook)
expected_checks=[cid for st in plan['stages'] for cid in st['check_ids']]
assert len(expected_checks)==len(set(expected_checks))==60
assert sorted(manual_ids)==sorted(expected_checks)
for st in plan['stages']:
 if st['id']!='S00':
  assert re.search(r'^## '+st['id']+r'\b',handbook,re.M)
 assert re.search(r'^## '+st['id']+r'\b',(DESIGN/plan['development_plan']).read_text(),re.M)
 assert all(cid.startswith(st['id']+'-') for cid in st['check_ids'])
template=(DESIGN/plan['evidence_template']).read_text()
for required in ('身份与范围','阶段检查项','功能编号与回归','性能与视觉','缺陷与未执行项','结论与下一步'):
 assert '## '+required in template
passed('60 stage checklist items, matching handbook/development sections and evidence template')

profiles=json.loads((DESIGN/'contracts/platform-profiles.json').read_text())['profiles']
assert len(profiles)==3
expected={'linux':('active','linux','x86_64-unknown-linux-gnu'),'android':('planned','android','aarch64-linux-android'),'windows':('planned','windows','x86_64-pc-windows-msvc')}
for p in profiles:
 assert (p['status'],p['flutter_target'],p['rust_target'])==expected[p['platform']]
 assert set(p['adapters'])=={'storage','source','secrets','scheduler','codec','instance_lock'}
 assert p['ui']['layout']=='adaptive'
 assert all(type(v) is int and v>0 for v in p['limits'].values())
 assert p['limits']['original_parallelism']<=p['limits']['transfer_parallelism']
 assert p['limits']['decoder_single_mib']<=p['limits']['decoder_total_mib']
 assert p['limits']['gallery_rows_limit']<=2000
passed('Linux-first and planned Android/Windows profile design samples')
tokens=json.loads((DESIGN/'ux/glass-tokens.json').read_text())
assert tokens['quality']['full']['max_normal_viewport_area_ratio']<=0.2
assert tokens['quality']['plain']['max_live_surfaces']==0
assert tokens['quality']['plain']['blur_sigma']==0
assert tokens['sizes']['touch_target_min']>=48
assert tokens['light']['reading_alpha_floor']>=.9
assert tokens['dark']['reading_alpha_floor']>=.9
passed('glass quality, area, touch and reading alpha budgets')
def rgb(h):return [int(h[i:i+2],16)/255 for i in (1,3,5)]
def lum(rgb):return sum(w*(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4) for w,v in zip((.2126,.7152,.0722),rgb))
def contrast(a,b):
 x,y=sorted((lum(a),lum(b)));return (y+.05)/(x+.05)
for mode in ('light','dark'):
 t=tokens[mode];alpha=t['reading_alpha_floor'];fill=rgb(t['reading_fill'])
 for base in ([0,0,0],[1,1,1]):
  bg=[alpha*f+(1-alpha)*b for f,b in zip(fill,base)]
  assert contrast(rgb(t['foreground']),bg)>=4.5
ov=tokens['photo_overlay'];alpha=ov['scrim_alpha_floor'];bg=[(1-alpha)]*3
assert contrast(rgb(ov['foreground']),bg)>=4.5
passed('reading/photo-overlay token contrast against black and white sample backgrounds')

schema=(DESIGN/'contracts/local-schema.sql').read_text()
c=sqlite3.connect(':memory:');c.executescript(schema)
tables=[r[0] for r in c.execute("select name from sqlite_master where type='table'")]
indexes=c.execute("select count(*) from sqlite_master where type='index' and sql is not null").fetchone()[0]
assert len(tables)==41,(len(tables),tables)
strict={r[1]:r[5] for r in c.execute('pragma table_list')}
assert all(strict[t]==1 for t in tables)
for t in tables:
 for row in c.execute(f'pragma table_info({t})'):
  assert row[2].upper()!='BLOB'
  assert not re.search(r'(payload_json|request_json|access_token|lease_token|download_url|password)',row[1],re.I)
assert c.execute('pragma foreign_key_check').fetchall()==[]
passed(f'{len(tables)} STRICT tables, {indexes} explicit indexes, no document/credential payload columns')

for a in ('a','b'):
 insert(c,'accounts',account_id=a,endpoint_origin='https://test.invalid',remote_user_id='user-'+a,username=a,auth_state='signed_out',created_at_ms=0)
for a,j,z in [('a','ja','A'),('a','ja2','Other'),('b','jb','B')]:
 insert(c,'jobs',account_id=a,job_id=j,namespace_container='c',namespace_environment='production',namespace_database='private',zone_name=z,owner_name='_defaultOwner',database_generation='gen',protocol_version=1)
for a,e,j in [('a','e','ja'),('a','e2','ja'),('a','e3','ja2'),('b','eb','jb')]:
 insert(c,'sync_entries',account_id=a,entry_id=e,job_id=j,logical_path=e+'.jpg',metadata_version=1,content_version=1,created_at_ms=0)
expect_rejected(c,'INSERT INTO accounts(account_id,endpoint_origin,remote_user_id,username,auth_state,created_at_ms) VALUES(NULL,?,?,?,?,?)',('x','null','null','signed_out',0))
expect_rejected(c,'INSERT INTO sync_entries(account_id,entry_id,job_id,created_at_ms) VALUES(?,?,?,?)',('a','bad','jb',0))
expect_rejected(c,"UPDATE sync_entries SET ack_metadata_version=2 WHERE account_id='a' AND entry_id='e'")
expect_rejected(c,"UPDATE sync_entries SET desired_favorite='invalid' WHERE account_id='a' AND entry_id='e'")
expect_rejected(c,'INSERT INTO sync_entries(account_id,entry_id,job_id,logical_path,created_at_ms) VALUES(?,?,?,?,?)',('a','dup','ja','e.jpg',0))
c.execute("UPDATE sync_entries SET cloud_photo_id='same-photo' WHERE entry_id IN ('e','eb')")
expect_rejected(c,"UPDATE sync_entries SET cloud_photo_id='same-photo' WHERE account_id='a' AND entry_id='e2'")
passed('null IDs, cross-account job access, duplicate identity/path, bad types and invalid ack rejected')

for a,e in [('a','e'),('a','e2'),('b','eb')]:
 insert(c,'media_versions',account_id=a,entry_id=e,version_id='v',original_relpath='managed/'+e+'/original',thumbnail_relpath='managed/'+e+'/thumbnail.jpg',original_sha256='0'*64,original_size=100,thumbnail_sha256='1'*64,thumbnail_size=10,original_mime='image/jpeg',thumbnail_mime='image/jpeg',width=10,height=10,state='published',created_at_ms=0,verified_at_ms=0)
 insert(c,'media_items',account_id=a,entry_id=e,current_version_id='v',sort_time_ms=0,availability='ready')
expect_rejected(c,"INSERT INTO media_items VALUES('a','e3','missing',0,'ready')")
expect_rejected(c,"DELETE FROM media_versions WHERE account_id='a' AND entry_id='e' AND version_id='v'")
expect_rejected(c,"UPDATE media_versions SET thumbnail_size=0 WHERE account_id='a' AND entry_id='e'")
expect_rejected(c,"UPDATE media_versions SET verified_at_ms=NULL WHERE account_id='a' AND entry_id='e'")
passed('visible-version FK, positive resource sizes, verified proof and retained current version')
insert(c,'library_groups',account_id='a',group_path='',total_count=2,favorite_count=0)
for e in ('e','e2'):insert(c,'library_memberships',account_id='a',group_path='',entry_id=e,sort_time_ms=0,favorite=0)
expect_rejected(c,"INSERT INTO library_memberships VALUES('a','','eb',0,0)")
expect_rejected(c,"UPDATE library_groups SET favorite_count=3 WHERE account_id='a' AND group_path=''")
passed('read projection ownership and bounded group counts')

for a,st,j,purpose in [('a','rq','ja','issued_request'),('a','rs','ja','issued_result'),('a','other','ja2','receive')]:
 insert(c,'record_sets',account_id=a,set_id=st,job_id=j,purpose=purpose)
insert(c,'sync_records',account_id='a',record_row_id='r',set_id='rq',record_name='p',record_type='CPLAsset')
insert(c,'record_fields',account_id='a',record_row_id='r',field_name='title',kind='STRING',text_value='example')
insert(c,'record_fields',account_id='a',record_row_id='r',field_name='obsolete',kind='DELETE_FIELD')
insert(c,'record_fields',account_id='a',record_row_id='r',field_name='tags',kind='STRING_LIST')
insert(c,'record_list_values',account_id='a',record_row_id='r',field_name='tags',list_kind='STRING_LIST',position=0,item_kind='STRING',text_value='first')
insert(c,'record_events',account_id='a',record_row_id='r',category='metadata',event_time_ms=123,event_source='device',event_id='event')
expect_rejected(c,"INSERT INTO record_fields(account_id,record_row_id,field_name,kind,text_value) VALUES('a','r','wrong','INT64','x')")
expect_rejected(c,"INSERT INTO record_fields(account_id,record_row_id,field_name,kind,text_value,integer_value) VALUES('a','r','both','STRING','x',1)")
expect_rejected(c,"INSERT INTO record_list_values(account_id,record_row_id,field_name,list_kind,position,item_kind,integer_value) VALUES('a','r','tags','STRING_LIST',1,'INT64',1)")
assert c.execute("SELECT kind FROM record_fields WHERE field_name='obsolete'").fetchone()==('DELETE_FIELD',)
passed('typed scalar/list fields, null patch distinction and captured event rows')

insert(c,'runs',account_id='a',run_id='run',job_id='ja',process_id='process',epoch=1,config_generation=1,trigger_kind='manual',state='running',started_at_ms=0)
insert(c,'runs',account_id='a',run_id='run-other',job_id='ja2',process_id='process',epoch=1,config_generation=1,trigger_kind='manual',state='running',started_at_ms=0)
base=dict(account_id='a',operation_id='op',job_id='ja',entry_id='e',issued_run_id='run',config_generation=1,phase='modify',state='prepared',captured_metadata_version=1,captured_content_version=1,captured_delete_version=0,request_set_id='rq',request_finalized=1,request_sha256='2'*64,created_at_ms=0)
insert(c,'issued_operations',**base)
for changes in [dict(operation_id='bad-no-hash',entry_id='e2',request_sha256=None),dict(operation_id='bad-run',entry_id='e2',issued_run_id='run-other'),dict(operation_id='bad-set',entry_id='e2',request_set_id='other')]:
 vals=base|changes;sql='INSERT INTO issued_operations('+','.join(vals)+') VALUES('+','.join('?' for _ in vals)+')';expect_rejected(c,sql,tuple(vals.values()))
expect_rejected(c,"INSERT INTO issued_record_actions VALUES('a','op',0,'rq','r','update',NULL)")
insert(c,'issued_record_actions',account_id='a',operation_id='op',position=0,request_set_id='rq',record_row_id='r',action='update',expected_revision='rev')
expect_rejected(c,"INSERT INTO issued_operations SELECT account_id,'op-duplicate',job_id,entry_id,issued_run_id,config_generation,phase,state,captured_metadata_version,captured_content_version,captured_delete_version,prepared_version_id,request_set_id,result_set_id,request_finalized,atomic_batch,request_sha256,server_result_code,created_at_ms FROM issued_operations WHERE operation_id='op'")
expect_rejected(c,"INSERT INTO resource_work(account_id,work_id,job_id,entry_id,role,direction,expected_sha256,expected_size,state,config_generation) VALUES('a','bad','ja2','e','original','download',?,1,'needed',1)",('0'*64,))
passed('issued request hash/revision, one unsettled op and cross-job result/resource bindings')
insert(c,'job_config_intents',account_id='a',intent_id='cfg',job_id='ja',base_generation=1,target_generation=2,upload_scope='none',state='accepted',accepted_at_ms=0)
expect_rejected(c,"INSERT INTO job_config_intents VALUES('a','cfg2','ja',1,3,'none','accepted',0)")
expect_rejected(c,"UPDATE job_config_intents SET target_generation=1 WHERE intent_id='cfg'")
passed('single pending configuration and monotonic target generation')

insert(c,'receive_rounds',account_id='a',round_id='round',job_id='ja',kind='bootstrap',state='receiving',config_generation=1,database_generation='gen',created_at_ms=0)
insert(c,'receive_streams',account_id='a',round_id='round',stream_id='master',record_type='CPLMaster')
c.commit()
c.execute('SAVEPOINT page')
insert(c,'record_sets',account_id='a',set_id='page-set',job_id='ja',purpose='receive')
insert(c,'sync_records',account_id='a',record_row_id='page-record',set_id='page-set',record_name='m',record_type='CPLMaster')
insert(c,'receive_pages',account_id='a',round_id='round',stream_id='master',page_no=0,job_id='ja',request_cursor_digest='3'*64,set_id='page-set')
insert(c,'inbox_events',account_id='a',event_id='page-event',round_id='round',stream_id='master',page_no=0,ordinal=0,set_id='page-set',record_row_id='page-record',state='pending')
c.execute("UPDATE receive_streams SET continuation_marker='next' WHERE account_id='a' AND round_id='round'")
c.execute('ROLLBACK TO page');c.execute('RELEASE page')
assert c.execute("SELECT continuation_marker FROM receive_streams WHERE round_id='round'").fetchone()==(None,)
assert c.execute("SELECT count(*) FROM sync_records WHERE record_row_id='page-record'").fetchone()==(0,)
expect_rejected(c,"INSERT INTO receive_pages(account_id,round_id,stream_id,page_no,job_id,request_cursor_digest,set_id) VALUES('a','round','master',0,'ja',?,'other')",('4'*64,))
passed('receive page/marker sample rollback and wrong-job page set rejection')

queries=[('all-window',"SELECT entry_id,sort_time_ms FROM library_memberships WHERE account_id='a' AND group_path='' ORDER BY sort_time_ms DESC,entry_id DESC LIMIT 100",'idx_membership_order'),('favorites',"SELECT entry_id,sort_time_ms FROM library_memberships WHERE account_id='a' AND group_path='' AND favorite=1 ORDER BY sort_time_ms DESC,entry_id DESC LIMIT 100",'idx_membership_favorite_order'),('deep-path',"SELECT entry_id,sort_time_ms FROM library_memberships WHERE account_id='a' AND group_path='A/B/C' ORDER BY sort_time_ms DESC,entry_id DESC LIMIT 100",'idx_membership_order'),('groups',"SELECT group_path,total_count FROM library_groups WHERE account_id='a' AND parent_path='' ORDER BY group_path LIMIT 100",'idx_group_children'),('dirty',"SELECT entry_id FROM sync_entries WHERE account_id='a' AND job_id='ja' AND dirty_kind='modify' LIMIT 20",'idx_entry_dirty'),('resources',"SELECT work_id FROM resource_work WHERE account_id='a' AND job_id='ja' AND state='needed' LIMIT 20",'idx_resource_pending'),('publication',"SELECT 1 FROM publication_intents WHERE account_id='a' AND entry_id='e' AND state='prepared' LIMIT 1",'idx_publication_entry_state')]
plans={}
for name,q,index in queries:
 sql_plan=' | '.join(str(r[3]) for r in c.execute('EXPLAIN QUERY PLAN '+q));plans[name]=sql_plan
 assert index in sql_plan,(name,sql_plan)
 assert 'TEMP B-TREE' not in sql_plan and 'SCAN ' not in sql_plan,(name,sql_plan)
passed('7 key query plans use expected indexes without full scan or sort temp table')
assert c.execute('pragma foreign_key_check').fetchall()==[]
assert c.execute('pragma integrity_check').fetchone()==('ok',)
passed('fixture foreign_key_check and integrity_check')

files=[ROOT/'README.md', *sorted((ROOT/'docs').rglob('*.md'))]
link_count=0
for p in files:
 text=p.read_text();assert text.count('```')%2==0,p
 for line in text.splitlines():assert line==line.rstrip(),p
 for link in re.findall(r'\]\(([^)]+)\)',text):
  if '://' in link:continue
  path,_,anchor=link.partition('#');target=(p.parent/path).resolve() if path else p
  assert target.exists(),(p,link)
  if anchor and target.suffix=='.md':
   headings=re.findall(r'^#{1,6}\s+(.+)$',target.read_text(),re.M)
   slugs=[re.sub(r'[^\w\- ]','',h.lower()).replace(' ','-') for h in headings]
   assert anchor in slugs,(p,link,slugs)
  link_count+=1
passed(f'Markdown local links/anchors, code fences and whitespace ({link_count} links)')
report={'scope':'design_only_not_application_validation','check_groups':len(checks),'checks':checks,'module_count':len(mods),'application_stage_count':len(plan['stages'])-1,'stage_checklist_count':len(expected_checks),'acceptance_ids_planned':len(allids),'application_tests_executed':0,'sql_tables':len(tables),'sql_explicit_indexes':indexes,'sqlite_version':sqlite3.sqlite_version,'local_links':link_count,'query_plans':plans}
parser=argparse.ArgumentParser(description='Validate design contracts; no application tests or user data access.')
parser.add_argument('--report',type=Path)
args=parser.parse_args()
if args.report: args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('RESULT',json.dumps({k:v for k,v in report.items() if k not in ('checks','query_plans')},ensure_ascii=False))
