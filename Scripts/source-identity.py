"""Identity of actual build inputs, including uncommitted/untracked source."""
from pathlib import Path
import hashlib,json,plistlib,subprocess,sys
root=Path(__file__).resolve().parents[1]
def git(*args):
 result=subprocess.run(['git',*args],cwd=root,text=True,capture_output=True)
 return result.stdout.strip() if result.returncode==0 else None
def identity():
 digest=hashlib.sha256()
 paths=[]
 for name in ('Sources','Resources','ThirdParty'):
  paths.extend(p for p in (root/name).rglob('*') if p.is_file() and '.git' not in p.parts and '__pycache__' not in p.parts and p.name!='.DS_Store')
 paths.extend(root/'Scripts'/name for name in ('build.sh','native-ink-flags.sh','Info.plist','InkConfiguration.cc','source-identity.py','protect-build-output.py','publish-app.py'))
 for path in sorted(paths):
  digest.update(str(path.relative_to(root)).encode()+b'\0');digest.update(path.read_bytes())
 return dict(commit=git('rev-parse','HEAD'),dirty=bool(git('status','--porcelain','--untracked-files=all')),sourceSHA256=digest.hexdigest())
if __name__=='__main__':
 value=identity()
 if len(sys.argv)>1:
  path=Path(sys.argv[1]);info=plistlib.loads(path.read_bytes())
  info.update(EcruSourceSHA256=value['sourceSHA256'],EcruSourceCommit=value['commit'] or 'source-archive',EcruWorkspaceDirty=value['dirty'])
  path.write_bytes(plistlib.dumps(info))
 else:print(json.dumps(value,sort_keys=True))
