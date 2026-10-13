"""Atomic publication after checking again for a newly launched candidate."""
import ctypes,os,sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
protect=SourceFileLoader('protect',str(Path(__file__).with_name('protect-build-output.py'))).load_module().protect
source,target=sys.argv[1:];protect(target)
if os.path.exists(target):
 libc=ctypes.CDLL(None,use_errno=True)
 if libc.renamex_np(os.fsencode(source),os.fsencode(target),2):
  raise OSError(ctypes.get_errno(),'Atomic App exchange failed; previous App retained')
else:os.rename(source,target)
