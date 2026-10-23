#!/bin/zsh
# Self-contained public regressions; no personal handwriting recordings required.
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries .build/module-cache output/pdf
[[ -f output/pdf/reader-test-original.pdf ]] || "$ECRU_TEST_PYTHON" Scripts/make_fixture.py
task_test_variant="${ECRU_VARIANT:-development}"
task_test_name="Ecru"
task_test_folder="$PWD/.build/apps"
[[ "$task_test_variant" != development ]] || task_test_folder+="/development"
export ECRU_TEST_APP_PATH="${ECRU_TEST_APP_PATH:-$task_test_folder/$task_test_name.app}"
source Scripts/ensure-test-app.sh
flags=(-swift-version 5 -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache")
if [[ "${1:-}" == "--ui" ]]; then
  task_bundle="$PWD/.build/apps/PublicWindow-$ecru_arch.app"
  trap 'rm -rf "$task_bundle"' EXIT
  mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
  xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" -O -whole-module-optimization -D ECRU_UI_TESTS Sources/*.swift Tests/PublicWindowChecks.swift -o "$task_bundle/Contents/MacOS/PublicWindow" -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
  cp -R Resources/Preview "$task_bundle/Contents/Resources/"
  "$ECRU_TEST_PYTHON" - "$task_bundle/Contents/Info.plist" <<'PY'
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
"$ECRU_TEST_PYTHON" Tests/BrandingTests.py
"$ECRU_TEST_PYTHON" Tests/InputBoundaryTests.py
for task_test in Ink Storage Annotation InkNatural InkDamage; do
  case "$task_test" in
    Ink) task_sources=(Sources/InkCore.swift Tests/InkLegacyReference.swift);;
    Storage|Annotation) task_sources=(Sources/InkCore.swift Sources/DocumentSession.swift Sources/AnnotationChange.swift Sources/RecoveryStore.swift Sources/PDFPagePreservation.swift Sources/AnnotationModel.swift Sources/ImageObjects.swift);;
    *) task_sources=(Sources/InkCore.swift);;
  esac
  xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" "${task_sources[@]}" "Tests/${task_test}Tests.swift" -o ".build/test-binaries/${task_test}Tests" -framework AppKit -framework PDFKit
  ".build/test-binaries/${task_test}Tests" "$PWD/.build/test-binaries/ink-roundtrip.pdf"
done
node Tests/PreviewTests.js
zsh Scripts/test-image-objects.sh
zsh Scripts/test-laser.sh
zsh Scripts/test-writing-tools.sh --synthetic
zsh Scripts/test-google-ink-synthetic.sh
zsh Scripts/test-complex-pdf.sh
zsh Scripts/test-local-annotations.sh
zsh Scripts/test-stability.sh
print "Public core regression passed ($ecru_arch)."
