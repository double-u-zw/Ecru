#!/bin/zsh
set -euo pipefail
task_test_entry="${0:A}"
cd "${0:A:h:h}"
source Scripts/test-environment.sh
source Scripts/native-ink-flags.sh
task_phase="${1:-after}"
[[ "$task_phase" == before || "$task_phase" == after ]]
mkdir -p .build/stability .build/module-cache
"$ECRU_TEST_PYTHON" Scripts/make_stability_fixtures.py .build/stability
task_sources=(Sources/*.swift)
task_extra=(-D STABILITY_INCREMENTAL)
if [[ "$task_phase" == before ]]; then
 [[ -n "${ECRU_BENCHMARK_REF:-}" ]] || {print -u2 'Set ECRU_BENCHMARK_REF to the unchanged baseline commit.';exit 1;}
 task_snapshot="$PWD/.build/stability/baseline"
 mkdir -p "$task_snapshot"
 git archive "$ECRU_BENCHMARK_REF" Sources | tar -x -C "$task_snapshot"
 # This round keeps the native handwriting recipe/parameters exactly fixed.
 cmp Sources/Native/AdaptivePositionModel.h "$task_snapshot/Sources/Native/AdaptivePositionModel.h"
 task_sources=("$task_snapshot"/Sources/*.swift);task_extra=()
fi
xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -O -D ECRU_INPUT_TESTS "${task_extra[@]}" -target "$ecru_arch-apple-macosx13.0" -module-cache-path "$PWD/.build/module-cache" "${task_sources[@]}" Tests/StabilityBenchmark.swift -o ".build/stability/$task_phase-benchmark" -framework AppKit -framework PDFKit -framework WebKit -framework UniformTypeIdentifiers
for task_scenario in large ordinary undo search; do
 ".build/stability/$task_phase-benchmark" "$PWD/.build/stability" "$PWD/.build/stability/$task_phase-$task_scenario.json" "$task_scenario"
done
"$ECRU_TEST_PYTHON" - "$task_phase" <<'PY'
from pathlib import Path
import hashlib,json,sys
p=Path('.build/stability');phase=sys.argv[1];result={}
for scenario in ('large','ordinary','undo','search'):result.update(json.loads((p/f'{phase}-{scenario}.json').read_text()))
result['samples']={name:hashlib.sha256((p/(name+'.pdf')).read_bytes()).hexdigest() for name in ('large','ordinary','search')}
(p/(phase+'.json')).write_text(json.dumps(result,indent=2,sort_keys=True))
print('Measured isolated process workloads:',p/(phase+'.json'))
PY
