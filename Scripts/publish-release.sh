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
[[ -f "$task_directory/Ecru-$task_version-arm64.dmg" ]]
(cd "$task_directory" && shasum -a 256 -c SHA256SUMS.txt)
task_head="$(git rev-parse HEAD)"
task_ci="$(gh run list --repo "$task_repo" --workflow build.yml --commit "$task_head" --status success --json headSha,conclusion --limit 10)"
python3 - "$task_head" "$task_ci" <<'PYCI'
import json,sys
assert any(r['headSha']==sys.argv[1] and r['conclusion']=='success' for r in json.loads(sys.argv[2])), 'Matching frozen-source CI has not passed'
PYCI
if git rev-parse "$task_tag^{commit}" >/dev/null 2>&1; then
 [[ "$(git rev-parse "$task_tag^{commit}")" == "$task_head" ]] || { print -u2 'Existing tag points to different source; refusing to replace it.'; exit 1; }
else
 git tag -a "$task_tag" -m "Ecru $task_version"
fi
git push origin "$task_tag"
gh release create "$task_tag" --repo "$task_repo" --verify-tag --draft --prerelease --title "Ecru $task_version" --notes-file "$task_directory/RELEASE_NOTES.md" "$task_directory/Ecru-$task_version-arm64.dmg" "$task_directory/SHA256SUMS.txt" "$task_directory/INSTALL.txt" "$task_directory/RELEASE_NOTES.md"

task_download="$(mktemp -d "$PWD/.build/release-download.XXXXXX")"
# A failure leaves the release as a draft for review; never publishes bad assets.
gh release download "$task_tag" --repo "$task_repo" --dir "$task_download"
python3 Scripts/verify-release-assets.py "$task_directory" "$task_download"
gh release edit "$task_tag" --repo "$task_repo" --draft=false --prerelease
