#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import json, subprocess, sys, time, uuid
from pathlib import Path
image=sys.argv[1]
root=Path(sys.argv[2]).resolve(); root.mkdir(parents=True,exist_ok=True)
arch=sys.argv[3]
metadata=json.loads((root/'metadata.json').read_text())
expected_version=next(x.split('=',1)[1] for x in metadata['build_args'] if x.startswith('VERSION='))
suffix=uuid.uuid4().hex[:8]
volume='obzorarr-validation-'+arch+'-'+suffix
name=volume
result={'architecture':arch,'volume':volume,'image':image,'checks':[]}
def docker(*args, check=True):
 r=subprocess.run(['docker',*args],capture_output=True,text=True,timeout=90)
 if check and r.returncode: raise RuntimeError('docker '+args[0]+' failed: '+r.stderr[:1000])
 return (r.stdout+r.stderr if args[0]=='logs' else r.stdout).strip()
def js(code): return json.loads(docker('exec',name,'bun','-e',code))
def ready():
 for _ in range(60):
  try:
   r=js("const r=await fetch('http://127.0.0.1:4321/',{signal:AbortSignal.timeout(1000)});const s=await r.text();console.log(JSON.stringify({status:r.status,url:r.url,obzorarr:s.toLowerCase().includes('obzorarr'),version:s.includes("+json.dumps(expected_version[:7])+")}))")
   if r['status']==200 and r['obzorarr'] and r['version']: return r
  except Exception: pass
  time.sleep(1)
 raise RuntimeError('HTTP readiness failed')
def stop():
 start=time.monotonic(); docker('stop','--time','15',name)
 state=json.loads(docker('inspect',name))[0]['State']
 assert state['ExitCode']==0 and not state['OOMKilled'],state
 elapsed=time.monotonic()-start
 assert elapsed<15,elapsed
 return round(elapsed,3)
def start():
 docker('run','-d','--name',name,'--network','none','-e','PUID=12345','-e','PGID=12345','-e','PORT=4321','-e','TZ=UTC','-v',volume+':/config',image)
def database(write=False):
 code="import {Database} from 'bun:sqlite'; const d=new Database('/config/data/obzorarr.db'); "
 if write: code+="d.exec(\"CREATE TABLE packaging_probe (value TEXT NOT NULL); INSERT INTO packaging_probe VALUES ('retained'); INSERT OR REPLACE INTO app_settings (key,value) VALUES ('sync_scheduler_state','running'),('sync_cron_expression','0 0 1 1 *')\"); "
 code+="console.log(JSON.stringify({integrity:d.query('PRAGMA integrity_check').get(),marker:d.query('SELECT value FROM packaging_probe').get(),migrations:d.query('SELECT count(*) AS n FROM __drizzle_migrations').get(),scheduler:d.query(\"SELECT value FROM app_settings WHERE key='sync_scheduler_state'\").get()})); d.close();"
 r=js(code); assert r['marker']['value']=='retained' and r['migrations']['n']==11 and r['integrity']['integrity_check']=='ok' and r['scheduler']['value']=='running',r
 return r
try:
 docker('volume','create',volume)
 start(); result['checks'].append({'fresh':ready()})
 info=js("import {readdirSync,readFileSync,statSync,realpathSync} from 'node:fs'; const pids=readdirSync('/proc').filter(x=>/^\\d+$/.test(x)); const app=pids.map(p=>{try{return {pid:p,cmd:readFileSync('/proc/'+p+'/cmdline','utf8').split('\\0'),status:readFileSync('/proc/'+p+'/status','utf8')}}catch{return null}}).find(p=>p && p.cmd.length===3 && p.cmd[0]==='bun' && p.cmd[1]==='./build/index.js'); const st=statSync('/config/data/obzorarr.db'); console.log(JSON.stringify({bun:Bun.version,arch:process.arch,production:process.env.NODE_ENV,tag:process.env.COMMIT_TAG,data:realpathSync('/app/data'),uid:st.uid,gid:st.gid,app:app?{pid:app.pid,uid:app.status.match(/Uid:\\s+(\\d+)/)[1]}:null}));")
 assert info['tag']==expected_version
 assert info['bun']=='1.4.2' and info['production']=='production' and info['data']=='/config/data',info
 assert info['uid']==12345 and info['gid']==12345 and info['app']['uid']=='12345',info
 assert info['arch']=={'amd64':'x64','arm64':'arm64'}[arch],info
 result['checks'].append({'runtime':info,'database':database(True)})
 (root/'packages.txt').write_text(docker('exec',name,'apk','info','-v')+'\n')
 result['checks'].append({'first_stop_seconds':stop()})
 docker('start',name); result['checks'].append({'restart':ready(),'database':database()})
 result['checks'].append({'second_stop_seconds':stop()})
 docker('cp',name+':/config/data',str(root/(volume+'-backup')))
 docker('rm',name)
 start(); result['checks'].append({'replacement':ready(),'database':database()})
 result['checks'].append({'replacement_stop_seconds':stop()})
 result['passed']=True
 (root/'result.txt').write_text('PASS: native HTTP/version/migrations/UID/persistence/restart/replacement/clean shutdown\n')
finally:
 logs=docker('logs',name,check=False)
 log=root/(volume+'.log');log.write_text(logs);log.chmod(0o600)
 docker('stop','--time','15',name,check=False)
 docker('rm',name,check=False)
 (root/'runtime-result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
