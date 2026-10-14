"""One compact result per top-level invocation, with source and actual App identity."""
from pathlib import Path
import hashlib,json,os,plistlib,subprocess,sys,uuid,datetime,time,platform
from importlib.machinery import SourceFileLoader
root=Path(__file__).resolve().parents[1]
identity=SourceFileLoader('source_identity',str(root/'Scripts/source-identity.py')).load_module().identity
run_id=str(uuid.uuid4());directory=root/'.build/test-results';directory.mkdir(parents=True,exist_ok=True)
report=dict(command=sys.argv[1:],source=identity(),startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),status='running')
report.update(hostArchitecture=platform.machine(),requestedArchitecture=os.getenv('ECRU_ARCH',platform.machine()))
started=time.time()
def test_inputs():
 digest=hashlib.sha256()
 for path in sorted([*(root/'Tests').rglob('*'),*(root/'Scripts').rglob('*')]):
  if path.is_file() and path.suffix in ('.swift','.py','.sh','.js','.mjs','.json','.pdf','.txt') and '__pycache__' not in path.parts:
   digest.update(str(path.relative_to(root)).encode()+b'\0');digest.update(path.read_bytes())
 return digest.hexdigest()
report['testSourceSHA256']=test_inputs()
path=directory/(run_id+'.json')
def app_identity():
 folder=root/'.build/apps' if os.getenv('ECRU_VARIANT')=='release' else root/'.build/apps/development'
 app=Path(os.getenv('ECRU_TEST_APP_PATH',folder/'Ecru.app'))
 try:
  info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
  return dict(path=str(app),info={k:info.get(k) for k in ('CFBundleIdentifier','CFBundleVersion','EcruReleaseVersion','EcruBuildRevision','EcruSourceSHA256','EcruSourceCommit','EcruWorkspaceDirty')},architectures=subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/Ecru')],text=True).strip().split(),executableSHA256=hashlib.sha256((app/'Contents/MacOS/Ecru').read_bytes()).hexdigest())
 except FileNotFoundError:return dict(path=str(app),available=False)
report['appBefore']=app_identity();path.write_text(json.dumps(report,indent=2))
try:
 result=subprocess.run(['zsh',*sys.argv[1:]],cwd=root,env=dict(os.environ,ECRU_TEST_RUN_ID=run_id,ECRU_TEST_ENV_VALIDATED='0'))
 report.update(exitCode=result.returncode,status='passed' if result.returncode==0 else 'failed')
except BaseException:
 report.update(exitCode=1,status='interrupted');raise
finally:
 report.update(sourceAfter=identity(),app=app_identity(),finishedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
 report['testSourceSHA256After']=test_inputs()
 report['executables']={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'.build/test-binaries').glob('*') if p.is_file() and p.stat().st_mtime>=started and os.access(p,os.X_OK)}
 if report['sourceAfter']['sourceSHA256']!=report['source']['sourceSHA256'] or report['testSourceSHA256After']!=report['testSourceSHA256']:
  report.update(status='invalidated',exitCode=1,reason='Source or test inputs changed during the run; rerun against a stable checkout.')
 path.write_text(json.dumps(report,indent=2));print('Test result:',path,flush=True)
sys.exit(report['exitCode'])
