#!/bin/zsh
# Run explicitly after accepting the candidate UI. Never replaces an existing release.
set -euo pipefail
cd "${0:A:h:h}"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :EcruReleaseVersion' Scripts/Info.plist)"
task_repo="double-u-zw/Ecru"
task_tag="v$task_version"
[[ "$task_version" != *-rc.* ]] || { print -u2 "UI candidate: update version to an accepted beta before publication."; exit 1; }
[[ "$task_version" != *-dev.* ]] || { print -u2 "Development versions cannot be published."; exit 1; }
[[ -z "$(git status --porcelain)" ]]
[[ "$(git remote get-url origin)" == *double-u-zw/Ecru* ]]
if gh release view "$task_tag" --repo "$task_repo" >/dev/null 2>&1; then
 print -u2 "Release already exists; existing assets will not be changed."; exit 1
fi
task_directory="$PWD/output/releases/$task_version"
python3 Scripts/verify-release.py "$task_directory"
[[ -f "$task_directory/Ecru-$task_version-arm64.dmg" && -f "$task_directory/Ecru-$task_version-x86_64.dmg" ]]
(cd "$task_directory" && shasum -a 256 -c SHA256SUMS.txt)
if ! git rev-parse "$task_tag" >/dev/null 2>&1; then git tag -a "$task_tag" -m "Ecru $task_version"; fi
git push origin "$task_tag"
gh release create "$task_tag" --repo "$task_repo" --verify-tag --prerelease --title "Ecru $task_version" --notes-file "$task_directory/RELEASE_NOTES.md" "$task_directory/Ecru-$task_version-arm64.dmg" "$task_directory/Ecru-$task_version-x86_64.dmg" "$task_directory/SHA256SUMS.txt" "$task_directory/INSTALL.txt" "$task_directory/RELEASE_NOTES.md"
