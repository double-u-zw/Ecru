#!/bin/zsh
# Signed/notarized candidate preparation only. Never installs or publishes.
set -euo pipefail
cd "${0:A:h:h}"
: "${ECRU_SIGN_IDENTITY:?Set the Developer ID Application identity}"
: "${ECRU_SIGN_TEAM:?Set the signing Team ID}"
: "${ECRU_NOTARY_PROFILE:?Set the local notarytool Keychain profile name}"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :EcruReleaseVersion' Scripts/Info.plist)"
[[ ! -e "$PWD/output/releases/$task_version" ]] || { print -u2 'Candidate directory already exists; preserve it and select a new version.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Freeze a clean source checkout first.'; exit 1; }
[[ "${ECRU_ALLOW_ADHOC:-0}" != 1 ]] || { print -u2 'Official candidate preparation requires Developer ID.'; exit 1; }
python3 Scripts/release-signing.py preflight
task_app="$PWD/.build/apps/arm64/Ecru.app"
ECRU_VARIANT=release ECRU_ARCH=arm64 ECRU_RELEASE=1 ECRU_APP_OUTPUT="$task_app" zsh Scripts/build.sh
python3 Scripts/release-signing.py notarize "$task_app"
ECRU_APP_PATH="$task_app" zsh Scripts/package-beta.sh
python3 Scripts/verify-release.py "$PWD/output/releases/$task_version"
