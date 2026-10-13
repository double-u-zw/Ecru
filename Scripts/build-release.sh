#!/bin/zsh
# Prepare an Apple Silicon candidate only; publication requires separate authorization.
set -euo pipefail
cd "${0:A:h:h}"
task_app="$PWD/.build/apps/arm64/Ecru.app"
ECRU_VARIANT=release ECRU_ARCH=arm64 ECRU_RELEASE=1 ECRU_APP_OUTPUT="$task_app" zsh Scripts/build.sh
ECRU_APP_PATH="$task_app" zsh Scripts/package-beta.sh
