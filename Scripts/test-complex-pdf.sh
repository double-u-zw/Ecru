#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Set ECRU_TEST_PYTHON to a runtime with Tests/requirements.txt installed.
task_python="${ECRU_TEST_PYTHON:-python3}"
mkdir -p .build/complex-pdf .build/test-binaries .build/module-cache
"$task_python" Scripts/make_complex_pdf_fixtures.py .build/complex-pdf/fixtures
source Scripts/native-ink-flags.sh
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/InkCore.swift Sources/DocumentSession.swift Sources/PDFPagePreservation.swift Sources/AnnotationModel.swift Sources/ImageObjects.swift Tests/ComplexPDFTests.swift -o .build/test-binaries/ComplexPDFTests -framework AppKit -framework PDFKit
.build/test-binaries/ComplexPDFTests | tee .build/complex-pdf/results.txt
task_run="$(sed -n 's/.*Artifacts: //p' .build/complex-pdf/results.txt | tail -1)"
"$task_python" Tests/inspect_complex_pdf.py "$task_run"
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -target "$ecru_arch-apple-macosx13.0" -D ECRU_INPUT_TESTS -module-cache-path "$PWD/.build/module-cache" Sources/*.swift Tests/ComplexPDFWindowTests.swift -o .build/test-binaries/ComplexPDFWindowTests -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
.build/test-binaries/ComplexPDFWindowTests
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/InkCore.swift Sources/DocumentSession.swift Sources/PDFPagePreservation.swift Sources/AnnotationModel.swift Sources/ImageObjects.swift Tests/PDFKitCapabilityProbe.swift -o .build/test-binaries/PDFKitCapabilityProbe -framework AppKit -framework PDFKit
.build/test-binaries/PDFKitCapabilityProbe | tee .build/complex-pdf/pdfkit-probe.txt
"$task_python" Tests/verify_signature_fixture.py "$PWD/.build/complex-pdf"
