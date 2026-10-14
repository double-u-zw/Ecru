#!/usr/bin/env python3
"""Verify immutable release DMGs and their complete copied Apps, without installing."""
from pathlib import Path
import hashlib, json, os, plistlib, re, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[1]
directory = Path(sys.argv[1]).resolve()
def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def inventory(folder):
    return {str(p.relative_to(folder)): digest(p) for p in folder.rglob('*') if p.is_file()}

expected = plistlib.loads((root/'Scripts/Info.plist').read_bytes())
version = expected['EcruReleaseVersion']
assert '-dev.' not in version
assert directory.name == version
revision = run('git', '-C', str(root), 'rev-parse', '--short', 'HEAD')
assert not run('git', '-C', str(root), 'status', '--porcelain'), 'Freeze a clean checkout before verification'
files = {f'Ecru-{version}-{arch}.dmg' for arch in ('arm64',)}
checksums = {}
for line in (directory/'SHA256SUMS.txt').read_text().splitlines():
    value, name = line.split('  ', 1)
    assert re.fullmatch('[0-9a-f]{64}', value) and name in files and name not in checksums
    checksums[name] = value
assert set(checksums) == files
assert version in (directory/'INSTALL.txt').read_text()
assert version in (directory/'RELEASE_NOTES.md').read_text()
report = {'version': version, 'build': expected['CFBundleVersion'], 'sourceCommit': run('git','-C',str(root),'rev-parse','HEAD'), 'signing': 'Developer ID Application; Apple notarized and stapled', 'architectures': {}, 'scope': 'Local release preparation; no installed application or user PDF modified'}
(root/'.build/apps').mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.release-verification.', dir=root/'.build/apps') as workspace:
    workspace = Path(workspace)
    resource_inventories, infos = [], []
    for arch in ('arm64',):
        dmg = directory/f'Ecru-{version}-{arch}.dmg'
        assert digest(dmg) == checksums[dmg.name]
        run('hdiutil', 'verify', str(dmg))
        mount = workspace/f'mount-{arch}'
        mount.mkdir()
        attached = False
        try:
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(dmg))
            attached = True
            assert (mount/'Applications').is_symlink() and os.readlink(mount/'Applications') == '/Applications'
            assert (mount/'Read Me.txt').read_bytes() == (directory/'INSTALL.txt').read_bytes()
            app = workspace/f'Ecru-{arch}.app'
            run('ditto', str(mount/'Ecru.app'), str(app))
            info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
            for key in ('CFBundleIdentifier','CFBundleVersion','CFBundleShortVersionString','EcruReleaseVersion','LSMinimumSystemVersion'):
                assert info[key] == expected[key], (arch, key)
            assert info['CFBundleName'] == 'Ecru' and info['CFBundleDisplayName'] == 'Ecru'
            assert info['EcruBuildRevision'] == revision and 'EcruBuildChannel' not in info
            binary = app/'Contents/MacOS/Ecru'
            assert run('lipo', '-archs', str(binary)) == arch
            assert re.search(r'(?:minos|version) 13\.0(?:\s|$)', run('otool','-l',str(binary)))
            dependencies = run('otool','-L',str(binary)).splitlines()[1:]
            assert all(v.strip().startswith(('/System/Library/', '/usr/lib/')) for v in dependencies)
            run('codesign','--verify','--strict',str(app))
            from importlib.machinery import SourceFileLoader
            signing = SourceFileLoader('release_signing', str(root/'Scripts/release-signing.py')).load_module()
            team = os.environ['ECRU_SIGN_TEAM']
            signing.verify(app, team); signing.verify(dmg, team)
            run('xcrun','stapler','validate',str(app))
            run('xcrun','stapler','validate',str(dmg))
            run('spctl','--assess','--type','execute','--verbose=4',str(app))
            run('spctl','--assess','--type','open','--context','context:primary-signature','--verbose=4',str(dmg))
            source = SourceFileLoader('identity', str(root/'Scripts/source-identity.py')).load_module().identity()
            assert info['EcruSourceCommit'] == source['commit'] and info['EcruSourceSHA256'] == source['sourceSHA256'] and info['EcruWorkspaceDirty'] is False
            assert list((app/'Contents/MacOS').iterdir()) == [binary]
            resources = app/'Contents/Resources'
            assert not list((resources/'InkSource').glob('*.h')) and not list((resources/'InkSource').glob('*.cc'))
            configuration = json.loads((resources/'InkSource/parameters.json').read_text())
            assert configuration['version'] == version and str(configuration['build']) == expected['CFBundleVersion']
            assert configuration['recipe'] == info['EcruPenRecipe'] == 'google-ink-daily-v5'
            assert configuration['sourceSHA256'] == digest(root/'Sources/Native/AdaptivePositionModel.h')
            licenses = inventory(resources/'Licenses')
            assert licenses == inventory(mount/'Licenses') and len(licenses) >= 8
            built = root/f'.build/apps/{arch}/Ecru.app'
            assert inventory(app) == inventory(built), 'DMG content differs from frozen build'
            resource_inventories.append(inventory(resources)); infos.append(info)
            report['architectures'][arch] = {'dmg': dmg.name, 'sha256': checksums[dmg.name], 'appFiles': len(inventory(app)), 'licenseFiles': len(licenses), 'readOnlyMountAndCompleteCopiedBundleVerified': True, 'deploymentTarget': '13.0', 'signatureVerified': True, 'signingTeam': team, 'appAndDMGTicketsValidated': True, 'gatekeeperAccepted': True, 'systemLibrariesOnly': True}
        finally:
            if attached:
                run('hdiutil','detach',str(mount))
(directory/'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(f'PASS: {version} ({expected["CFBundleVersion"]}), Apple Silicon read-only DMG, complete copied Apps, signatures, architecture, licenses and exact source identity verified')
