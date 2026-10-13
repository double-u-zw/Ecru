"""Exercise guards/failure cleanup without touching installed Apps."""
from pathlib import Path
import os,plistlib,subprocess,tempfile,hashlib,time
root=Path(__file__).resolve().parents[1]
def rejected(path):
 result=subprocess.run(['zsh','Scripts/build.sh'],cwd=root,env=dict(os.environ,ECRU_APP_OUTPUT=str(path)),text=True,capture_output=True)
 assert result.returncode!=0 and 'installed Ecru/Ecru Dev are protected' in result.stderr,result.stderr
for directory in (Path('/Applications'),Path.home()/'Applications'):
 for name in ('Ecru.app','Ecru Dev.app'):
  rejected(directory/name);rejected(directory/name/'nested.app')
with tempfile.TemporaryDirectory(dir=root/'.build/apps',prefix='.guard-') as temporary:
 folder=Path(temporary);alias=folder/'alias.app';alias.symlink_to('/Applications/Ecru Dev.app');rejected(alias)
 # Force compiler failure by prepending an xcrun stub. The prior artifact is immutable.
 app=folder/'candidate.app';app.mkdir();(app/'marker').write_bytes(b'previous usable output')
 before=set((root/'.build/apps').glob('.app-bundle.*'))
 stub=folder/'bin';stub.mkdir();executable=stub/'xcrun';executable.write_text('#!/bin/sh\nexit 91\n');executable.chmod(0o755)
 result=subprocess.run(['zsh','Scripts/build.sh'],cwd=root,env=dict(os.environ,ECRU_APP_OUTPUT=str(app),PATH=str(stub)+os.pathsep+os.environ['PATH']),capture_output=True)
 assert result.returncode!=0 and (app/'marker').read_bytes()==b'previous usable output'
 assert set((root/'.build/apps').glob('.app-bundle.*'))==before,'failed build leaked a temporary bundle'
 # A tiny synthetic native executable exercises the running-candidate guard.
 binary=app/'Contents/MacOS/probe';binary.parent.mkdir(parents=True)
 subprocess.run(['xcrun','clang','-x','c','-o',str(binary),'-'],input='#include <unistd.h>\nint main(void){sleep(30);return 0;}\n',text=True,check=True)
 running=subprocess.Popen([str(binary)])
 try:
  time.sleep(0.05)
  result=subprocess.run(['zsh','Scripts/build.sh'],cwd=root,env=dict(os.environ,ECRU_APP_OUTPUT=str(app)),text=True,capture_output=True)
  assert result.returncode!=0 and 'candidate App is running' in result.stderr,result.stderr
 finally:running.terminate();running.wait()
print('PASS: installed App paths/symlinks protected; failed build retains previous output and cleans staging')
