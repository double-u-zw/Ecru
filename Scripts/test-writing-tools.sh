#!/bin/zsh
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries output
task_corpus=(-D ECRU_PRIVATE_CORPUS)
if [[ "${1:-}" == --synthetic ]]; then task_corpus=(); fi
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -D ECRU_INPUT_TESTS "${task_corpus[@]}" -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" Sources/*.swift Tests/WritingToolsTests.swift -o .build/test-binaries/WritingToolsTests -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers -framework WebKit
.build/test-binaries/WritingToolsTests | tee output/writing-tools-results.txt
