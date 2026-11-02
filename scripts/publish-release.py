#!/usr/bin/env python3
"""Upload only reviewed release artifacts. Uses existing local Git credentials."""
import argparse,hashlib,json,plistlib,subprocess,urllib.parse
from pathlib import Path
from github_api import api
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--notes',type=Path,required=True);p.add_argument('--publish',action='store_true');p.add_argument('--appcast',type=Path,default=root/'dist/appcast.xml');a=p.parse_args()
d=plistlib.loads((root/'Info.plist').read_bytes());version=d['CFBundleShortVersionString'];tag='v'+version;base='/repos/cjy20010719/fanyi-yixia'
assert api('GET',base)['private'] is False,'Release repository must be public'
tracked=subprocess.check_output(['git','ls-files'],cwd=root,text=True).splitlines()
assert not any(Path(f).suffix in ('.key','.pem','.p12','.p8','.ed25519') or 'Yi-private' in f or f.startswith(('backups/','dist/','Vendor/')) for f in tracked),'Private/build files must not be tracked'
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
files=[root/'dist/releases'/f'Yi-{version}-universal.dmg',root/'dist/releases'/f'Yi-{version}-universal.zip',root/'dist/releases/INSTALL.zh-CN.txt',root/'dist/releases/SHA256SUMS.txt',a.appcast]
assert all(f.is_file() for f in files),'Build and sign all artifacts before publishing'
# Fixed allowlist prevents accidentally uploading private keys, preferences or backups.
assert all(f.suffix in ('.dmg','.zip','.txt','.xml') for f in files)
releases=api('GET',base+'/releases?per_page=100');matches=[r for r in releases if r['tag_name']==tag];assert len(matches)<=1
r=matches[0] if matches else api('POST',base+'/releases',{'tag_name':tag,'target_commitish':head,'name':'翻译一下 '+version+' — macOS 通用安装包','body':a.notes.read_text(),'draft':True,'prerelease':False})
for f in files:
 digest='sha256:'+hashlib.sha256(f.read_bytes()).hexdigest()
 existing=[x for x in r['assets'] if x['name']==f.name]
 if existing:
  assert existing[0]['digest']==digest and existing[0]['size']==f.stat().st_size,'Existing release artifact differs; never overwrite a published package'
 else:
  assert r['draft'],'Refusing to change published release artifacts'
  url=r['upload_url'].split('{')[0]+'?name='+urllib.parse.quote(f.name)
  uploaded=api('POST',url,raw=f.read_bytes(),content_type='application/octet-stream')
  assert uploaded['state']=='uploaded' and uploaded['digest']==digest and uploaded['size']==f.stat().st_size
 print('Verified asset:',f.name,flush=True)
if a.publish and r['draft']:
 r=api('PATCH',base+'/releases/'+str(r['id']),{'draft':False,'make_latest':'true','body':a.notes.read_text(),'target_commitish':head})
print(json.dumps({'url':r['html_url'],'draft':r['draft'],'id':r['id']},ensure_ascii=False))
