#!/usr/bin/env python3
from pathlib import Path
import hashlib,plistlib,subprocess,sys
root=Path(__file__).resolve().parents[1]
s=(root/'Sources/main.m').read_text();block=s[s.index('- (void)updateStatusIcon {'):s.index('- (NSTextField *)label:')]
assert hashlib.sha256(block.encode()).hexdigest()=='3e729f0e59bfbf5ee6b95fe56a18bd9d51c5beec384ee4441318af6bf91927a0','Menu bar icon implementation changed'
p=plistlib.loads((root/'Info.plist').read_bytes())
assert p['CFBundleIdentifier']=='local.chenshanglong.Translate'
assert p['SUFeedURL']=='https://cjy20010719.github.io/fanyi-yixia/appcast.xml'
assert p['SUPublicEDKey']=='kOg7EiYbSf1G9V1V0JtVkfSQiIeqse2VA7R7n9RGJv0='
assert p['SUVerifyUpdateBeforeExtraction'] and p['SURequireSignedFeed']
assert p['SUSignedFeedFailureExpirationInterval']==0
assert 'NSAppTransportSecurity' not in p,'Production ATS must remain enabled'
assert 'SPUStandardUpdaterController' in s and 'addUpdateItems:menu' in s
if '--source-only' not in sys.argv:
 app=root/'dist/翻译一下.app'
 assert (app/'Contents/Resources/AppIcon.icns').read_bytes()==(root/'Assets/AppIcon.icns').read_bytes()
 assert (app/'Contents/Resources/MenuBarIcon.png').read_bytes()==(root/'Assets/MenuBarIcon.png').read_bytes()
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 subprocess.run(['lipo',str(app/'Contents/MacOS/翻译一下'),'-verify_arch','arm64','x86_64'],check=True)
print('PASS: menu icon verified; bundle ID, updater security, universal build and app icon verified')
