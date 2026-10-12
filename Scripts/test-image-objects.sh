#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -D ECRU_INPUT_TESTS -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/*.swift Tests/ImageObjectTests.swift -o .build/test-binaries/ImageObjectTests -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
.build/test-binaries/ImageObjectTests | tee .build/image-objects-results.txt
task_image_root="$(sed -n 's/.*Artifacts: //p' .build/image-objects-results.txt | tail -1)"
"${ECRU_TEST_PYTHON:-python3}" Tests/inspect_image_pdf.py "$task_image_root/fill-and-images.pdf"
