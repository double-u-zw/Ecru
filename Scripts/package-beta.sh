#!/bin/zsh
# Package the already-built, verified release App. Includes complete license notices.
set -euo pipefail
cd "${0:A:h:h}"
task_app="${ECRU_APP_PATH:-$PWD/output/Ecru.app}"
task_docs="${ECRU_RELEASE_DOCS:-$PWD}"
if [[ -z "${ECRU_RELEASE_DOCS:-}" && -d "$PWD/OpenSource" ]]; then task_docs="$PWD/OpenSource"; fi
task_version="$(/usr/libexec/PlistBuddy -c 'Print :EcruReleaseVersion' "$task_app/Contents/Info.plist")"
task_arch="$(lipo -archs "$task_app/Contents/MacOS/Ecru")"
if [[ "$task_arch" == "arm64 x86_64" || "$task_arch" == "x86_64 arm64" ]]; then task_arch="universal"; fi
[[ "$task_arch" == "universal" || "$task_arch" == "arm64" || "$task_arch" == "x86_64" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")" == local.leafink.reader.development ]] || { print -u2 "Package an explicit release build, not Ecru Dev."; exit 1; }
[[ ! -f "$task_app/Contents/Resources/InkSource/AdaptivePositionModel.h" ]]
codesign --verify --strict "$task_app"
task_release="$PWD/output/releases/$task_version"
mkdir -p "$task_release"
task_dmg="$task_release/Ecru-$task_version-$task_arch.dmg"
[[ ! -e "$task_dmg" ]] || { print -u2 "Already exists: $task_dmg"; exit 1; }
task_stage="$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
ditto "$task_app" "$task_stage/Ecru.app"
ln -s /Applications "$task_stage/Applications"
cp "$task_docs/INSTALL.txt" "$task_stage/Read Me.txt"
cp -R "$task_app/Contents/Resources/Licenses" "$task_stage/Licenses"
hdiutil create -volname "Ecru $task_version" -srcfolder "$task_stage" -format UDZO -ov "$task_dmg"
hdiutil verify "$task_dmg"
cp "$task_docs/INSTALL.txt" "$task_release/INSTALL.txt"
cp "$task_docs/RELEASE_NOTES.md" "$task_release/RELEASE_NOTES.md"
python3 - "$task_dmg" "$task_release/SHA256SUMS.txt" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(''.join(hashlib.sha256(item.read_bytes()).hexdigest()+'  '+item.name+'\n' for item in sorted(p.parent.glob('Ecru-*.dmg'))))
PY
print "Packaged: $task_dmg"
