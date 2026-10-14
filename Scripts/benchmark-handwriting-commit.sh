#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_test_entry="${0:A}"
source Scripts/test-environment.sh
[[ $# == 1 ]] || { print -u2 'Usage: zsh Scripts/benchmark-handwriting-commit.sh <baseline-commit>'; exit 1; }
task_ref="$(git rev-parse --verify "$1^{commit}")"
source Scripts/native-ink-flags.sh
task_root="$(mktemp -d "$PWD/.build/handwriting-commit.XXXXXX")"
mkdir -p "$task_root/baseline" .build/module-cache
cp Tests/Fixtures/PDF/Ecru-Sample.pdf "$task_root/fixture.pdf"
git archive "$task_ref" Sources | tar -x -C "$task_root/baseline"
# Both executables intentionally link the same native library; reject a baseline
# with a different native engine rather than misattribute geometry differences.
for task_file in AdaptivePositionModel.h GoogleInkBridge.cc; do
 cmp "Sources/Native/$task_file" "$task_root/baseline/Sources/Native/$task_file"
done
for task_phase in before after; do
 if [[ "$task_phase" == before ]]; then task_sources=("$task_root"/baseline/Sources/*.swift); else task_sources=(Sources/*.swift); fi
 xcrun swiftc "${ecru_ink_flags[@]}" -swift-version 5 -O -whole-module-optimization -D ECRU_INPUT_TESTS -target arm64-apple-macosx13.0 -module-cache-path "$PWD/.build/module-cache" "${task_sources[@]}" Tests/HandwritingCommitBenchmark.swift -o "$task_root/$task_phase" -framework AppKit -framework PDFKit -framework WebKit -framework UniformTypeIdentifiers
done
# Alternate isolated processes after both compilations, reducing compiler noise.
for task_trial in 1 2 3; do
 for task_count in 1 1000 5000; do
  for task_phase in before after; do
   "$task_root/$task_phase" "$task_root" "$task_count" > "$task_root/$task_phase-$task_count-$task_trial.json"
  done
 done
done
"$ECRU_TEST_PYTHON" - "$task_root" "$task_ref" <<'PY'
from pathlib import Path
from importlib.machinery import SourceFileLoader
import hashlib,json,sys
p=Path(sys.argv[1]);identity=SourceFileLoader('identity','Scripts/source-identity.py').load_module().identity()
r={'baselineCommit':sys.argv[2],'workspace':identity,'appUsed':False,'recoveryHeldDuringSampling':True,'sampleSHA256':hashlib.sha256((p/'fixture.pdf').read_bytes()).hexdigest(),'executables':{phase:hashlib.sha256((p/phase).read_bytes()).hexdigest() for phase in ['before','after']},'runs':{f.stem:json.loads(f.read_text()) for f in sorted(p.glob('*-*-*.json'))}}
(p/'results.json').write_text(json.dumps(r,indent=2)+'\n')
print('Handwriting commit measurements:',p/'results.json')
PY
