#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -O -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/InkCore.swift Sources/AnnotationModel.swift Sources/ImageObjects.swift Sources/DocumentSession.swift Sources/PDFPagePreservation.swift Tests/ImagePerformanceTests.swift -o .build/test-binaries/ImagePerformanceTests -framework AppKit -framework PDFKit
.build/test-binaries/ImagePerformanceTests | tee .build/image-performance-results.txt
