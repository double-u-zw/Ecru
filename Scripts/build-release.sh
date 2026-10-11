#!/bin/zsh
# Two independent, identically versioned Apps/DMGs; no Rosetta needed to cross-build.
set -euo pipefail
cd "${0:A:h:h}"
task_host="$(uname -m)"
if [[ "$task_host" == arm64 ]]; then task_other=x86_64; else task_other=arm64; fi
task_host_app="$PWD/output/apps/$task_host/Ecru.app"
ECRU_VARIANT=release ECRU_ARCH="$task_host" ECRU_RELEASE=1 ECRU_APP_OUTPUT="$task_host_app" zsh Scripts/build.sh
ECRU_APP_PATH="$task_host_app" zsh Scripts/package-beta.sh
task_configuration="$task_host_app/Contents/Resources/InkSource/parameters.json"
task_other_app="$PWD/output/apps/$task_other/Ecru.app"
ECRU_VARIANT=release ECRU_ARCH="$task_other" ECRU_RELEASE=1 ECRU_CONFIGURATION_JSON="$task_configuration" ECRU_APP_OUTPUT="$task_other_app" zsh Scripts/build.sh
ECRU_APP_PATH="$task_other_app" zsh Scripts/package-beta.sh
