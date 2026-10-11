#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/native-ink-flags.sh
task_variant="${ECRU_VARIANT:-release}"
[[ "$task_variant" == release || "$task_variant" == development ]] || { print -u2 "ECRU_VARIANT must be release or development"; exit 1; }
task_name="Ecru"
[[ "$task_variant" != development ]] || task_name="Ecru Dev"
task_destination="${ECRU_APP_OUTPUT:-$PWD/output/$task_name.app}"
mkdir -p .build/module-cache output
# Publish a complete bundle: no abandoned executables or icon resources survive.
task_bundle="$(mktemp -d "$PWD/.build/app-bundle.XXXXXX")/Ecru.app"
mkdir -p "$task_bundle/Contents/MacOS"
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -target "$ecru_arch-apple-macosx13.0" -O -whole-module-optimization -module-cache-path "$PWD/.build/module-cache" Sources/*.swift -o "$task_bundle/Contents/MacOS/Ecru" -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
# Do not truncate an executable mapped by the reader that is protecting a draft.
# Compile into a separate bundle, then publish by rename on this filesystem.

cp Scripts/Info.plist "$task_bundle/Contents/Info.plist"
task_build_revision="$(git rev-parse --short HEAD 2>/dev/null || print source-archive)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then task_build_revision+="-dirty"; fi
/usr/libexec/PlistBuddy -c "Add :EcruBuildRevision string $task_build_revision" "$task_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :EcruPenRecipe string google-ink-daily-v5" "$task_bundle/Contents/Info.plist"
mkdir -p "$task_bundle/Contents/Resources/Licenses"
cp LICENSE "$task_bundle/Contents/Resources/Licenses/Ecru-Apache-2.0.txt"
cp NOTICE "$task_bundle/Contents/Resources/Licenses/Ecru-NOTICE.txt"
cp ThirdParty/google-ink/LICENSE "$task_bundle/Contents/Resources/Licenses/Google-Ink.txt"
cp ThirdParty/ink-stroke-modeler/LICENSE "$task_bundle/Contents/Resources/Licenses/Google-Ink-Stroke-Modeler.txt"
cp "$ecru_native_cache/build/_deps/abseil-cpp-src/LICENSE" "$task_bundle/Contents/Resources/Licenses/Abseil.txt"
cp -R Resources/Licenses/. "$task_bundle/Contents/Resources/Licenses/"
cp -R Resources/Preview "$task_bundle/Contents/Resources/"
cp -R Resources/*.lproj "$task_bundle/Contents/Resources/"
# A separately registered development app never shares preferences or drafts.
if [[ "$task_variant" == development ]]; then
 python3 - "$task_bundle" <<'PYDEV'
from pathlib import Path
import plistlib,sys
bundle=Path(sys.argv[1]);path=bundle/'Contents/Info.plist'
info=plistlib.loads(path.read_bytes())
info.update(CFBundleIdentifier='local.ecru.reader.development',CFBundleName='Ecru Dev',CFBundleDisplayName='Ecru Dev',EcruBuildChannel='development')
for document in info.get('CFBundleDocumentTypes',[]):document['LSHandlerRank']='Alternate'
path.write_bytes(plistlib.dumps(info))
for strings in (bundle/'Contents/Resources').glob('*.lproj/InfoPlist.strings'):
 strings.write_text('"CFBundleDisplayName" = "Ecru Dev";\n"CFBundleName" = "Ecru Dev";\n')
PYDEV
fi
task_icon_digest="$(shasum -a 256 Resources/Branding/AppIcon.icns | cut -c1-12)"
task_icon_name="EcruIcon-$task_icon_digest"
cp Resources/Branding/AppIcon.icns "$task_bundle/Contents/Resources/$task_icon_name.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $task_icon_name" "$task_bundle/Contents/Info.plist"
mkdir -p "$task_bundle/Contents/Resources/Licenses"
cp ThirdParty/perfect-freehand/LICENSE "$task_bundle/Contents/Resources/Licenses/perfect-freehand-MIT.txt"
# Export the parameters from the linked native library, and verify the exact
# position-model source before bundling it for future implementation audits.
mkdir -p "$task_bundle/Contents/Resources/InkSource"
if [[ -n "${ECRU_CONFIGURATION_JSON:-}" ]]; then
 cp "$ECRU_CONFIGURATION_JSON" "$task_bundle/Contents/Resources/InkSource/parameters.json"
else
 xcrun clang++ -arch "$ecru_arch" -mmacosx-version-min=13.0 -std=c++20 -O2 -framework CoreFoundation Scripts/InkConfiguration.cc "$ecru_native_cache/libEcruInkCombined.a" -o "${task_bundle:h}/InkConfiguration"
 "${task_bundle:h}/InkConfiguration" "$task_bundle/Contents/Resources/InkSource/parameters.json"
 rm "${task_bundle:h}/InkConfiguration"
fi
cp Sources/Native/AdaptivePositionModel.h Sources/Native/GoogleInkBridge.cc "$task_bundle/Contents/Resources/InkSource/"
python3 - "$task_bundle/Contents/Resources/InkSource" <<'PYINK'
import pathlib,hashlib,json,sys,plistlib
p=pathlib.Path(sys.argv[1]); c=json.loads((p/'parameters.json').read_text())
assert hashlib.sha256((p/'AdaptivePositionModel.h').read_bytes()).hexdigest()==c['sourceSHA256'], 'Model source changed during compilation'
info=plistlib.loads((p.parent.parent/'Info.plist').read_bytes())
assert c['build']==int(info['CFBundleVersion']) and c['version']==info.get('EcruReleaseVersion',info['CFBundleShortVersionString']) and c['recipe']==info['EcruPenRecipe'], 'Compiled identity and bundle mismatch'
PYINK
# Public binaries contain provenance parameters, never first-party source files.
if [[ "${ECRU_RELEASE:-0}" == "1" ]]; then
  rm "$task_bundle/Contents/Resources/InkSource/AdaptivePositionModel.h" "$task_bundle/Contents/Resources/InkSource/GoogleInkBridge.cc"
fi
codesign --force --sign - "$task_bundle"
codesign --verify --strict "$task_bundle"
mkdir -p "${task_destination:h}"
if [[ -d "$task_destination" ]]; then mv "$task_destination" "${task_bundle:h}/previous.app"; fi
mv "$task_bundle" "$task_destination"
rm -rf "${task_bundle:h}"
touch "$task_destination"
if [[ -z "${ECRU_APP_OUTPUT:-}" ]]; then
 /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$task_destination"
fi
print "Built ($ecru_arch): $task_destination"
