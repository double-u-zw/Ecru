"""Developer ID signing and resumable Apple notarization; never installs/publishes.

Credentials stay in Keychain. Environment contains only identity/team/profile names.
"""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, re, subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[1]

def run(*args, timeout=60):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr or result.stdout}')
    return result.stdout + result.stderr

def configuration():
    names = ('ECRU_SIGN_IDENTITY', 'ECRU_SIGN_TEAM', 'ECRU_NOTARY_PROFILE')
    values = {n: os.environ.get(n, '') for n in names}
    if not all(values.values()):
        raise ValueError('Set ECRU_SIGN_IDENTITY, ECRU_SIGN_TEAM and ECRU_NOTARY_PROFILE (Keychain profile name, never a password).')
    return values

def protected(path):
    path = Path(path).resolve()
    installed = (Path('/Applications').resolve(), (Path.home()/'Applications').resolve())
    if any(p == path or p in path.parents for p in installed):
        raise ValueError('Installed applications are protected.')
    allowed = (ROOT/'.build/apps').resolve() if path.suffix == '.app' else (ROOT/'output/releases').resolve()
    if allowed not in path.parents or path.suffix not in ('.app', '.dmg'):
        raise ValueError('Sign only candidate Apps beneath .build/apps or DMGs beneath output/releases.')
    if path.suffix == '.app':
        from importlib.machinery import SourceFileLoader
        SourceFileLoader('protect', str(ROOT/'Scripts/protect-build-output.py')).load_module().protect(path)
    return path

def verify(path, team):
    run('codesign', '--verify', '--strict', path)
    details = run('codesign', '-dv', '--verbose=4', path)
    if f'TeamIdentifier={team}\n' not in details or 'Authority=Developer ID Application:' not in details or 'Timestamp=' not in details:
        raise ValueError('Expected timestamped Developer ID Application signature for the selected team.')
    if Path(path).suffix == '.app':
        if not re.search(r'flags=.*\(.*runtime.*\)', details):
            raise ValueError('Hardened Runtime is required.')
        entitlements = run('codesign', '-d', '--entitlements', ':-', path)
        if '<?xml' in entitlements:
            e = plistlib.loads(entitlements[entitlements.index('<?xml'):entitlements.index('</plist>')+8].encode())
            if e:
                raise ValueError('Ecru requires no signing entitlements; unexpected permissions/debug exceptions found.')
    return details

def sign(path, config):
    path = protected(path)
    args = ['codesign', '--force', '--sign', config['ECRU_SIGN_IDENTITY'], '--timestamp']
    if path.suffix == '.app':
        info = plistlib.loads((path/'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != 'local.leafink.reader.development' or 'EcruBuildChannel' in info:
            raise ValueError('Developer ID candidate must retain the public release identity.')
        args += ['--options', 'runtime']
    run(*args, path)
    verify(path, config['ECRU_SIGN_TEAM'])

def digest(path):
    h = hashlib.sha256()
    if path.is_dir():
        for p in sorted(path.rglob('*')):
            if p.is_file():
                h.update(str(p.relative_to(path)).encode()+b'\0'); h.update(p.read_bytes())
    else:
        h.update(path.read_bytes())
    return h.hexdigest()

def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as f:
        json.dump(value, f, indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(temporary, path)

def accepted(result):
    if result.get('status') != 'Accepted':
        raise ValueError('Apple notarization did not accept this artifact: '+str(result.get('status')))

def notarize(path, config, timeout=900):
    path = protected(path); verify(path, config['ECRU_SIGN_TEAM'])
    before = digest(path)
    for completed in (ROOT/'.build/notary').glob('*/completed.json'):
        record = json.loads(completed.read_text())
        if record['stapledSHA256'] == before and record['team'] == config['ECRU_SIGN_TEAM']:
            accepted(record); run('xcrun', 'stapler', 'validate', path)
            print('Existing accepted/stapled candidate verified.', flush=True)
            return
    folder = ROOT/'.build/notary'/before; folder.mkdir(parents=True, exist_ok=True)
    receipt = folder/'submission.json'
    if receipt.exists():
        submission = json.loads(receipt.read_text())
    else:
        # An interrupted upload may already exist on Apple's service. Never
        # silently submit twice: retain stdout and require explicit reconciliation.
        output = folder/'submit-output.json'
        if output.exists():
            try:
                submission = json.loads(output.read_text())
                if not submission.get('id'): raise ValueError('Missing submission ID')
            except (ValueError, json.JSONDecodeError):
                raise RuntimeError(f'Prior upload outcome unknown. Reconcile notarytool history before removing {output}.')
        else:
            upload = path
            if path.suffix == '.app':
                upload = folder/'Ecru.zip'
                run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', path, upload)
            print('Submitting to Apple:', path.name, flush=True)
            with output.open('w') as f:
                result = subprocess.run(['xcrun', 'notarytool', 'submit', str(upload), '--keychain-profile', config['ECRU_NOTARY_PROFILE'], '--no-wait', '--no-s3-acceleration', '--output-format', 'json'], stdout=f, stderr=subprocess.PIPE, text=True, timeout=120)
                f.flush(); os.fsync(f.fileno())
            if result.returncode: raise RuntimeError(result.stderr)
            submission = json.loads(output.read_text())
        if not submission.get('id'): raise ValueError('Apple did not return a submission ID')
        write_json(receipt, submission)
    deadline = time.monotonic()+timeout
    while True:
        result = json.loads(run('xcrun', 'notarytool', 'info', submission['id'], '--keychain-profile', config['ECRU_NOTARY_PROFILE'], '--output-format', 'json'))
        write_json(folder/'status.json', result)
        print('Apple notarization:', result['status'], submission['id'], flush=True)
        if result['status'] != 'In Progress': break
        if time.monotonic() >= deadline:
            raise TimeoutError(f'Apple is still processing; rerun notarize for the same artifact to resume {submission["id"]}.')
        time.sleep(15)
    run('xcrun', 'notarytool', 'log', submission['id'], '--keychain-profile', config['ECRU_NOTARY_PROFILE'], folder/'log.json')
    accepted(result)
    if digest(path) != before: raise ValueError('Candidate changed while Apple was processing it.')
    run('xcrun', 'stapler', 'staple', path)
    run('xcrun', 'stapler', 'validate', path)
    verify(path, config['ECRU_SIGN_TEAM'])
    write_json(folder/'completed.json', dict(submissionID=submission['id'], status='Accepted', inputSHA256=before, stapledSHA256=digest(path), team=config['ECRU_SIGN_TEAM']))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('preflight', 'sign', 'verify', 'notarize'))
    parser.add_argument('path', nargs='?'); args = parser.parse_args()
    config = configuration()
    if args.action == 'preflight':
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning')
        matching = [line for line in identities.splitlines() if config['ECRU_SIGN_IDENTITY'] in line and 'Developer ID Application:' in line and f'({config["ECRU_SIGN_TEAM"]})' in line and 'CSSMERR' not in line]
        if not matching: raise ValueError('No usable Developer ID Application identity for the selected team.')
        json.loads(run('xcrun', 'notarytool', 'history', '--keychain-profile', config['ECRU_NOTARY_PROFILE'], '--output-format', 'json'))
        print('Developer ID and Keychain notarization credentials validated.')
    else:
        if not args.path: parser.error('path is required')
        if args.action == 'sign': sign(args.path, config)
        elif args.action == 'verify': verify(protected(args.path), config['ECRU_SIGN_TEAM'])
        else: notarize(args.path, config)

if __name__ == '__main__': main()
