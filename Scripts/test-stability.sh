#!/bin/zsh
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
source Scripts/native-ink-flags.sh
mkdir -p .build/test-binaries .build/module-cache output/pdf
[[ -f output/pdf/reader-test-original.pdf ]] || "$ECRU_TEST_PYTHON" Scripts/make_fixture.py
flags=(-swift-version 5 -O -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache")
xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" -D ECRU_INPUT_TESTS Sources/*.swift Tests/RecoveryRestartTests.swift -o .build/test-binaries/RecoveryRestartTests -framework AppKit -framework PDFKit -framework WebKit -framework UniformTypeIdentifiers
.build/test-binaries/RecoveryRestartTests
xcrun swiftc "${ecru_ink_flags[@]}" "${flags[@]}" -D ECRU_INPUT_TESTS Sources/*.swift Tests/SearchTests.swift -o .build/test-binaries/SearchTests -framework AppKit -framework PDFKit -framework WebKit -framework UniformTypeIdentifiers
.build/test-binaries/SearchTests
"$ECRU_TEST_PYTHON" Tests/BuildEntryTests.py
"$ECRU_TEST_PYTHON" Tests/ReleaseSigningTests.py
