#!/bin/zsh
# Package the already-built, verified release App. Includes complete license notices.
set -euo pipefail
cd "${0:A:h:h}"
task_app="${ECRU_APP_PATH:-$PWD/.build/apps/Ecru.app}"
task_docs="${ECRU_RELEASE_DOCS:-$PWD}"
if [[ -z "${ECRU_RELEASE_DOCS:-}" && -d "$PWD/OpenSource" ]]; then task_docs="$PWD/OpenSource"; fi
task_version="$(/usr/libexec/PlistBuddy -c 'Print :EcruReleaseVersion' "$task_app/Contents/Info.plist")"
task_arch="$(lipo -archs "$task_app/Contents/MacOS/Ecru")"
[[ "$task_arch" == "arm64" ]] || { print -u2 "Only Apple Silicon release candidates are supported."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")" == local.leafink.reader.development ]] || { print -u2 "Package an explicit release build, not Ecru Dev."; exit 1; }
[[ ! -f "$task_app/Contents/Resources/InkSource/AdaptivePositionModel.h" ]]
python3 Scripts/release-signing.py verify "$task_app"
xcrun stapler validate "$task_app"
task_release="$PWD/output/releases/$task_version"
[[ ! -e "$task_release" ]] || { print -u2 "Already exists: $task_release"; exit 1; }
mkdir -p "$PWD/output/releases"
task_pending="$PWD/output/releases/.$task_version-pending"
[[ ! -e "$task_pending" ]] || { print -u2 "Pending candidate exists: $task_pending; preserve/reconcile its notarization before retrying."; exit 1; }
mkdir "$task_pending"
task_dmg="$task_pending/Ecru-$task_version-$task_arch.dmg"
mkdir -p .build/apps
task_stage="$(mktemp -d "$PWD/.build/apps/.dmg-stage.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
ditto "$task_app" "$task_stage/Ecru.app"
ln -s /Applications "$task_stage/Applications"
cp "$task_docs/INSTALL.txt" "$task_stage/Read Me.txt"
cp -R "$task_app/Contents/Resources/Licenses" "$task_stage/Licenses"
hdiutil create -volname "Ecru $task_version" -srcfolder "$task_stage" -format UDZO -ov "$task_dmg"
hdiutil verify "$task_dmg"
python3 Scripts/release-signing.py sign "$task_dmg"
python3 Scripts/release-signing.py notarize "$task_dmg"
cp "$task_docs/INSTALL.txt" "$task_pending/INSTALL.txt"
cp "$task_docs/RELEASE_NOTES.md" "$task_pending/RELEASE_NOTES.md"
python3 - "$task_dmg" "$task_pending/SHA256SUMS.txt" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(''.join(hashlib.sha256(item.read_bytes()).hexdigest()+'  '+item.name+'\n' for item in sorted(p.parent.glob('Ecru-*.dmg'))))
PY
mv "$task_pending" "$task_release"
print "Packaged signed/notarized candidate: $task_release"
