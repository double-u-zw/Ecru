#!/bin/zsh
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries .build/module-cache
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -O -whole-module-optimization -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/InkCore.swift Sources/PerfectFreehand.swift Sources/PenBrush.swift Sources/ResponsivePenPath.swift Sources/ObservationStabilizer.swift Sources/ObservationPenBuilder.swift Sources/HandwritingEngine.swift Tests/GoogleInkTests.swift -o .build/test-binaries/GoogleInkSyntheticTests -framework AppKit -framework PDFKit
.build/test-binaries/GoogleInkSyntheticTests
print 'Current Google Ink synthetic geometry, pressure, time, zoom, release, erasure, long stroke and PDF appearance checks passed.'
