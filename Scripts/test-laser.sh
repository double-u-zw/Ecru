#!/bin/zsh
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries output
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -D ECRU_INPUT_TESTS -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/*.swift Tests/LaserTests.swift -o .build/test-binaries/LaserTests -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
.build/test-binaries/LaserTests "$@" | tee output/laser-results.txt
