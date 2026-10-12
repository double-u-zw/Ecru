#!/bin/zsh
# Two architecture-specific dependency graphs; one Universal 2 application.
set -euo pipefail
cd "${0:A:h:h}"
task_variant="${ECRU_VARIANT:-development}"
task_name="Ecru"
[[ "$task_variant" != development ]] || task_name="Ecru Dev"
mkdir -p .build/apps output
task_stage="$(mktemp -d "$PWD/.build/apps/.universal.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
task_host="$(uname -m)"
if [[ "$task_host" == "arm64" ]]; then task_other=x86_64; else task_other=arm64; fi
ECRU_VARIANT="$task_variant" ECRU_ARCH="$task_host" ECRU_APP_OUTPUT="$task_stage/$task_host.app" zsh Scripts/build.sh
# Export configuration on the host architecture. The foreign build uses the same
# source/configuration and verifies its model digest; building needs no emulator.
ECRU_VARIANT="$task_variant" ECRU_ARCH="$task_other" ECRU_APP_OUTPUT="$task_stage/$task_other.app" ECRU_CONFIGURATION_JSON="$task_stage/$task_host.app/Contents/Resources/InkSource/parameters.json" zsh Scripts/build.sh
python3 - "$task_stage" <<'PY'
import pathlib,sys,plistlib
p=pathlib.Path(sys.argv[1])
a,b=[p/name/'Contents' for name in ('arm64.app','x86_64.app')]
assert plistlib.loads((a/'Info.plist').read_bytes())==plistlib.loads((b/'Info.plist').read_bytes())
assert (a/'Resources/InkSource/parameters.json').read_bytes()==(b/'Resources/InkSource/parameters.json').read_bytes()
for f in (a/'Resources').rglob('*'):
 if f.is_file(): assert f.read_bytes()==(b/f.relative_to(a)).read_bytes(),f
PY
ditto "$task_stage/arm64.app" "$task_stage/Ecru.app"
lipo -create "$task_stage/arm64.app/Contents/MacOS/Ecru" "$task_stage/x86_64.app/Contents/MacOS/Ecru" -output "$task_stage/Ecru.app/Contents/MacOS/Ecru"
lipo "$task_stage/Ecru.app/Contents/MacOS/Ecru" -verify_arch arm64
lipo "$task_stage/Ecru.app/Contents/MacOS/Ecru" -verify_arch x86_64
codesign --force --sign - "$task_stage/Ecru.app"
codesign --verify --strict "$task_stage/Ecru.app"
if [[ -d ".build/apps/$task_name.app" ]]; then mv ".build/apps/$task_name.app" "$task_stage/previous.app"; fi
mv "$task_stage/Ecru.app" ".build/apps/$task_name.app"
print "Built Universal 2 (macOS 13+): $PWD/.build/apps/$task_name.app"
