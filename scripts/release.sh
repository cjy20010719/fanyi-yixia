#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# != 2 )); then print -u2 'Usage: zsh scripts/release.sh 1.0.1 docs/release-v1.0.1.md'; exit 1; fi
release_version="$1"
release_notes="$2"
[[ -f "$release_notes" ]] || { print -u2 'Write and commit release notes first'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit reviewed source and notes before releasing'; exit 1; }
git fetch origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { print -u2 'Release HEAD must match origin/main'; exit 1; }
python3 - "$release_version" <<'PY'
import plistlib,re,sys
from pathlib import Path
new=sys.argv[1];assert re.fullmatch(r'\d+\.\d+\.\d+',new),'Use a stable semantic version'
p=Path('Info.plist');d=plistlib.loads(p.read_bytes());old=d['CFBundleShortVersionString']
assert tuple(map(int,new.split('.')))>tuple(map(int,old.split('.'))),'Version must increase'
d.update(CFBundleShortVersionString=new,CFBundleVersion=str(int(d['CFBundleVersion'])+1));p.write_bytes(plistlib.dumps(d,sort_keys=False))
p=Path('README.md');s=p.read_text().replace('/v'+old+'/Yi-'+old+'-universal.dmg','/v'+new+'/Yi-'+new+'-universal.dmg');p.write_text(s)
PY
zsh package.sh
zsh scripts/test.sh
python3 scripts/verify-release.py
[[ ! -f docs/appcast.xml ]] || cp docs/appcast.xml dist/appcast.xml
python3 scripts/make-appcast.py "dist/releases/Yi-${release_version}-universal.zip" --url "https://github.com/cjy20010719/fanyi-yixia/releases/download/v${release_version}/Yi-${release_version}-universal.zip" --output dist/appcast.xml --notes "$(cat "$release_notes")"
git add Info.plist README.md "$release_notes"
git commit -m "Release Yi $release_version"
git tag "v$release_version"
git push origin main "v$release_version"
python3 scripts/publish-release.py --notes "$release_notes"
python3 scripts/publish-release.py --notes "$release_notes" --publish
cp dist/appcast.xml docs/appcast.xml
git add docs/appcast.xml
git commit -m "Publish signed update feed for $release_version"
git push origin main
print 'Release published. Verify GitHub Pages deployment and check for updates in Yi.'
