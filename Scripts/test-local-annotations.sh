#!/bin/zsh
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
"$ECRU_TEST_PYTHON" Scripts/make_complex_pdf_fixtures.py .build/complex-pdf/fixtures
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries .build/module-cache
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/InkCore.swift Sources/DocumentSession.swift Sources/AnnotationChange.swift Sources/RecoveryStore.swift Sources/PDFPagePreservation.swift Sources/AnnotationModel.swift Sources/ImageObjects.swift Tests/LocalAnnotationTests.swift -o .build/test-binaries/LocalAnnotationTests -framework AppKit -framework PDFKit
.build/test-binaries/LocalAnnotationTests | tee .build/local-annotations-results.txt
task_run="$(sed -n 's/.*Artifacts: //p' .build/local-annotations-results.txt | tail -1)"
"$ECRU_TEST_PYTHON" Tests/inspect_local_annotations.py "$task_run"
