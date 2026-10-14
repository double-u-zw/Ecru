"""Bundle and current brand audit. Historical PDF identifiers are data contracts."""
from pathlib import Path
import plistlib, hashlib, subprocess, os
root=Path(__file__).resolve().parents[1]
variant=os.environ.get('ECRU_VARIANT','development')
name='Ecru'
folder=root/'.build/apps/development' if variant=='development' else root/'.build/apps'
app=Path(os.environ.get('ECRU_TEST_APP_PATH',folder/f'{name}.app'))
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleExecutable']=='Ecru'
assert info['CFBundleIdentifier']==('local.ecru.reader.development' if variant=='development' else 'local.leafink.reader.development')
assert info['CFBundleDisplayName']==name
assert (info.get('EcruBuildChannel')=='development')==(variant=='development')
expected=plistlib.loads((root/'Scripts/Info.plist').read_bytes())
for key in ['CFBundleShortVersionString','CFBundleVersion','EcruReleaseVersion','LSMinimumSystemVersion']:
    assert info[key]==expected[key],f'Bundle/source version mismatch: {key}'
assert info['LSMinimumSystemVersion']=='13.0'
from importlib.machinery import SourceFileLoader
source=SourceFileLoader('identity',str(root/'Scripts/source-identity.py')).load_module().identity()
assert info['EcruSourceSHA256']==source['sourceSHA256'],'Tested App does not match current build inputs'
assert info['EcruWorkspaceDirty']==source['dirty'],'Tested App working-tree state differs'

import json
configuration=json.loads((app/'Contents/Resources/InkSource/parameters.json').read_text())
assert configuration['version']==info['EcruReleaseVersion']
assert str(configuration['build'])==info['CFBundleVersion']
assert info['EcruPenRecipe']=='google-ink-daily-v5'
assert 'google-ink-daily-v5' in (root/'Sources/HandwritingEngine.swift').read_text()
assert (app/'Contents/Resources/Licenses/Google-Ink.txt').is_file()
assert (app/'Contents/Resources/Licenses/Google-Ink-Stroke-Modeler.txt').is_file()
assert (app/'Contents/Resources/Licenses/Abseil.txt').is_file()
assert (app/'Contents/MacOS/Ecru').is_file()
assert len(list((app/'Contents/MacOS').iterdir()))==1
icon=(app/'Contents/Resources'/info['CFBundleIconFile']).with_suffix('.icns')
assert hashlib.sha256(icon.read_bytes()).digest()==hashlib.sha256((root/'Resources/Branding/AppIcon.icns').read_bytes()).digest()
for language in ['en','zh-Hans','zh-Hant']:
    localization=(app/'Contents/Resources'/f'{language}.lproj/InfoPlist.strings').read_text()
    assert name in localization
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
for folder in ['Sources','Scripts','Tests','Resources']:
    for path in (root/folder).rglob('*'):
        if path.suffix in ['.swift','.sh','.py','.plist','.strings']:
            import re
            assert not re.search(r'/Users/[^/\s]+/Desktop/',path.read_text()),path
print('PASS: executable, installation identity, version, three locales, exact approved icon, signature and portable current paths')

# First-party current code may only retain explicit compatibility contracts.
import re, json
allowed = ["local.leafink.reader.development", "LeafInkReaderWindow", "LeafInk-development",
           "/LeafInkStroke", "/LeafInkDocument", "/LeafInkMarkID", "/LeafInkNoteID", "/LeafInkAdapterID",
           "LeafInk-", "LeafInk text highlight", "LEAFINK_", "LEAFINK_UI_TESTS", "LEAFINK_DATA_DIR", "LEAFINK_COMPAT_TEST"]
rows=[]
for folder in ['Sources','Scripts','Tests']:
    for path in (root/folder).rglob('*'):
        if path==Path(__file__).resolve() or path.suffix not in ['.swift','.sh','.py','.plist','.js','.mjs','.html']: continue
        for number,line in enumerate(path.read_text().splitlines(),1):
            if not re.search('leafink',line,re.I):continue
            stripped=line
            for token in allowed:stripped=stripped.replace(token,'')
            assert not re.search('leafink',stripped,re.I),f'Unclassified old branding: {path}:{number}'
            rows.append({'file':str(path.relative_to(root)),'line':number,'category':'compatibility','text':line.strip()})
(root/'output/naming-audit.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
print(f'PASS: {len(rows)} remaining code references classified as compatibility; no unclassified current brand')
