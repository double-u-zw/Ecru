#!/bin/zsh
# Self-contained public regressions; no personal handwriting recordings required.
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries .build/module-cache output/pdf
[[ -f output/pdf/reader-test-original.pdf ]] || python3 Scripts/make_fixture.py
[[ -x output/Ecru.app/Contents/MacOS/Ecru ]] || ECRU_ARCH="$ecru_arch" zsh Scripts/build.sh
flags=(-swift-version 5 -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache")
if [[ "${1:-}" == "--ui" ]]; then
  task_bundle="$PWD/.build/test-binaries/PublicWindow-$ecru_arch.app"
  mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
  xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" -O -D ECRU_UI_TESTS Sources/*.swift Tests/PublicWindowChecks.swift -o "$task_bundle/Contents/MacOS/PublicWindow" -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
  cp -R Resources/Preview "$task_bundle/Contents/Resources/"
  python3 - "$task_bundle/Contents/Info.plist" <<'PY'
import plistlib,sys,pathlib
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.ecru.public-regression','CFBundleName':'Ecru UI Regression','CFBundleExecutable':'PublicWindow','CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True}))
PY
  codesign --force --sign - "$task_bundle"
  task_data="$(mktemp -d "$PWD/.build/public-ui.XXXXXX")"
  ECRU_ARCH="$ecru_arch" ECRU_DATA_DIR="$task_data" "$task_bundle/Contents/MacOS/PublicWindow" --ui-test "$PWD/output/pdf/reader-test-original.pdf" "$task_data/report.json"
  cp "$task_data/report.json" "output/public-ui-$ecru_arch.json"
  exit
fi
xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" -D ECRU_INPUT_TESTS Sources/*.swift Tests/InputLifecycleTests.swift -o .build/test-binaries/InputLifecycleTests -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
.build/test-binaries/InputLifecycleTests
python3 Tests/BrandingTests.py
python3 Tests/InputBoundaryTests.py
for task_test in Ink Storage Annotation InkNatural InkDamage; do
  case "$task_test" in
    Ink) task_sources=(Sources/InkCore.swift Tests/InkLegacyReference.swift);;
    Storage|Annotation) task_sources=(Sources/InkCore.swift Sources/DocumentSession.swift Sources/PDFPagePreservation.swift Sources/AnnotationModel.swift);;
    *) task_sources=(Sources/InkCore.swift);;
  esac
  xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" "${task_sources[@]}" "Tests/${task_test}Tests.swift" -o ".build/test-binaries/${task_test}Tests" -framework AppKit -framework PDFKit
  ".build/test-binaries/${task_test}Tests" "$PWD/.build/test-binaries/ink-roundtrip.pdf"
done
node Tests/PreviewTests.js
print "Public core regression passed ($ecru_arch)."
