# Sourced after changing to the repository root. Native dependencies are pinned;
# serialize cache creation so simultaneous test builds never rewrite an archive
# being linked by another compiler. There is no runtime network dependency.
ecru_arch="${ECRU_ARCH:-$(uname -m)}"
[[ "$ecru_arch" == "arm64" || "$ecru_arch" == "x86_64" ]]
ecru_native_cache="$PWD/.build/native-ink/$ecru_arch"
python3 - "$ecru_arch" <<'PY'
import fcntl, hashlib, os, pathlib, subprocess, sys
root=pathlib.Path.cwd()
arch=sys.argv[1]
cache=root/'.build/native-ink'/arch
cache.mkdir(parents=True,exist_ok=True)
with (cache/'build.lock').open('w') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 h=hashlib.sha256()
 for base in ('Sources/Native','ThirdParty/ink-stroke-modeler','ThirdParty/google-ink'):
  for p in sorted((root/base).rglob('*')):
   if p.is_file() and (p.suffix in ('.cc','.h','.cmake') or p.name=='CMakeLists.txt'):
    h.update(str(p.relative_to(root)).encode());h.update(p.read_bytes())
 key=h.hexdigest()
 library=cache/'libEcruInkCombined.a'
 stamp=cache/'fingerprint'
 if not library.exists() or not stamp.exists() or stamp.read_text().strip()!=key:
  def run(args,log):
   with (cache/log).open('w') as output:
    result=subprocess.run(args,stdout=output,stderr=subprocess.STDOUT)
   if result.returncode:
    print((cache/log).read_text())
    raise SystemExit(result.returncode)
  run(['cmake','-S','Sources/Native','-B',str(cache/'build'),'-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0', '-DCMAKE_OSX_ARCHITECTURES='+arch],'configure.log')
  run(['cmake','--build',str(cache/'build'),'--target','EcruInk','-j','6'],'build.log')
  temporary=cache/'libEcruInkCombined.next.a'
  run(['/usr/bin/libtool','-static','-o',str(temporary),*[str(p) for p in sorted((cache/'build').rglob('*.a'))]],'archive.log')
  os.replace(temporary,library)
  stamp.write_text(key+'\n')
PY
ecru_ink_flags=(-import-objc-header "$PWD/Sources/Native/InkModelerBridge.h" "$ecru_native_cache/libEcruInkCombined.a" -lc++)
