# The tested bundle must match current source, not just an existing executable.
task_app_fresh=0
if [[ -f "$ECRU_TEST_APP_PATH/Contents/Info.plist" ]]; then
 if python3 - "$ECRU_TEST_APP_PATH/Contents/Info.plist" <<'PYFRESH'
import sys,plistlib
sys.path.insert(0,'Scripts')
from importlib.machinery import SourceFileLoader
value=SourceFileLoader('identity','Scripts/source-identity.py').load_module().identity()
info=plistlib.load(open(sys.argv[1],'rb'))
raise SystemExit(0 if info.get('EcruSourceSHA256')==value['sourceSHA256'] and info.get('EcruSourceCommit')==(value['commit'] or 'source-archive') and info.get('EcruWorkspaceDirty')==value['dirty'] else 1)
PYFRESH
 then task_app_fresh=1; fi
fi
if [[ "$task_app_fresh" != 1 ]]; then ECRU_ARCH="$ecru_arch" ECRU_APP_OUTPUT="$ECRU_TEST_APP_PATH" zsh Scripts/build.sh; fi
