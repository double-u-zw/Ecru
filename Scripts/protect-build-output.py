"""Candidates stay in .build/apps; installed or running bundles are protected."""
from pathlib import Path
import ctypes,os,subprocess,sys
root=Path(__file__).resolve().parents[1]
def protect(destination):
 destination=Path(destination).resolve();allowed=(root/'.build/apps').resolve()
 installed_roots=[Path('/Applications'),Path.home()/'Applications']
 protected=[p.resolve() for parent in installed_roots for p in (parent,parent/'Ecru.app',parent/'Ecru Dev.app')]
 if destination==allowed or allowed not in destination.parents or destination.suffix!='.app' or any(destination==p or p in destination.parents for p in protected):
  raise SystemExit('Build output must be an App beneath .build/apps; installed Ecru/Ecru Dev are protected.')
 library=ctypes.CDLL('/usr/lib/libproc.dylib')
 for pid in subprocess.check_output(['ps','-axo','pid='],text=True).split():
  buffer=ctypes.create_string_buffer(4096)
  if library.proc_pidpath(int(pid),buffer,len(buffer))>0:
   executable=Path(os.fsdecode(buffer.value)).resolve()
   if destination in executable.parents:
    raise SystemExit('This candidate App is running; choose a different .build/apps output. No window was closed.')
 return destination
if __name__=='__main__':protect(sys.argv[1])
