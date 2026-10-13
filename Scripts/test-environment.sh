# Sourced by every test entry. A missing dependency fails the run, never skips it.
export ECRU_TEST_PYTHON="${ECRU_TEST_PYTHON:-$PWD/.venv/bin/python3}"
[[ -x "$ECRU_TEST_PYTHON" ]] || { print -u2 'Missing test Python. Run zsh Scripts/setup-tests.sh (or set ECRU_TEST_PYTHON).'; exit 1; }
if [[ -z "${ECRU_TEST_RUN_ID:-}" ]]; then
 exec "$ECRU_TEST_PYTHON" Scripts/run-test.py "$task_test_entry" "$@"
fi
if [[ "${ECRU_TEST_ENV_VALIDATED:-0}" != 1 ]]; then
"$ECRU_TEST_PYTHON" - <<'PYDEPS'
import importlib
for module in ('PIL','reportlab','pypdf','numpy','matplotlib','cryptography'):
 try:importlib.import_module(module)
 except ImportError:raise SystemExit(f'Missing required test dependency {module}; run zsh Scripts/setup-tests.sh.')
PYDEPS
export ECRU_TEST_ENV_VALIDATED=1
fi
