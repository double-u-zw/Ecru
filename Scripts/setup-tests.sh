#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
task_python="${ECRU_TEST_PYTHON:-python3}"
"$task_python" -c 'import sys; assert sys.version_info >= (3,12), "Tests require Python 3.12 or newer"'
"$task_python" -m venv .venv
.venv/bin/python3 -m pip install -r Tests/requirements.txt
print 'Test environment ready. Run zsh Scripts/test.sh or zsh Scripts/test-public.sh.'
