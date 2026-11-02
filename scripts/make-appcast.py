#!/usr/bin/env python3
"""Generate and EdDSA-sign an appcast. Signing key stays in local Keychain."""
import argparse,base64,datetime,os,plistlib,subprocess,xml.etree.ElementTree as ET,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('--url',required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--notes',default='Yi 更新：保持现有配置和翻译功能。');p.add_argument('--account',default='Yi-release');a=p.parse_args()
root=Path(__file__).resolve().parents[1];tool=root/'Vendor/Sparkle/bin/sign_update'
with zipfile.ZipFile(a.archive) as z:
 info=[n for n in z.namelist() if n.count('/')==2 and n.endswith('.app/Contents/Info.plist')]
 assert len(info)==1,info
 d=plistlib.loads(z.read(info[0]))
keyfile=Path(os.environ.get('YI_ED_KEY_FILE',str(root.parent/'Yi-private/sparkle-ed25519.key')))
signing=['--ed-key-file',str(keyfile)] if keyfile.exists() else ['--account',a.account]
sig=subprocess.check_output([str(tool),*signing,'-p',str(a.archive)],text=True).strip()
assert len(base64.b64decode(sig,validate=True))==64,'Signing did not return a valid EdDSA signature'
subprocess.run([os.environ.get('YI_NODE_PATH','node'),str(root/'scripts/verify-ed25519.cjs'),d['SUPublicEDKey'],sig,str(a.archive)],check=True)
ns='http://www.andymatuschak.org/xml-namespaces/sparkle';ET.register_namespace('sparkle',ns)
rss=ET.Element('rss',version='2.0');channel=ET.SubElement(rss,'channel');ET.SubElement(channel,'title').text='翻译一下更新';ET.SubElement(channel,'link').text='https://github.com/cjy20010719/fanyi-yixia';ET.SubElement(channel,'description').text='翻译一下 macOS updates'
item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text='翻译一下 '+d['CFBundleShortVersionString'];ET.SubElement(item,'pubDate').text=datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
for key,value in [('version',d['CFBundleVersion']),('shortVersionString',d['CFBundleShortVersionString']),('minimumSystemVersion',d['LSMinimumSystemVersion'])]:ET.SubElement(item,'{'+ns+'}'+key).text=value
ET.SubElement(item,'description').text=a.notes
ET.SubElement(item,'enclosure',url=a.url,length=str(a.archive.stat().st_size),type='application/octet-stream',attrib={'{'+ns+'}edSignature':sig})
if a.output.exists():
 old=ET.parse(a.output).getroot()
 for prior in old.findall('./channel/item'):
  if prior.findtext('{'+ns+'}version')!=d['CFBundleVersion'] and len(channel.findall('item'))<3:channel.append(prior)
a.output.parent.mkdir(parents=True,exist_ok=True)
ET.indent(rss);ET.ElementTree(rss).write(a.output,encoding='utf-8',xml_declaration=True)
subprocess.run([str(tool),*signing,str(a.output)],check=True)
subprocess.run([str(tool),*signing,'--verify',str(a.archive),sig],check=True)
subprocess.run([str(tool),*signing,'--verify',str(a.output)],check=True)
print('Signed and verified:',a.output)
