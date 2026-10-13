# Building Ecru

Ecru targets **macOS 13.0+** on Apple Silicon and Intel. The build uses Swift,
AppKit/PDFKit, C++20 and CMake directly; no Xcode project or private SDK is required.

## Development environment

Use a Mac with Xcode 15+ (or its matching Command Line Tools), CMake 3.19+,
Python 3.10+ and zsh. Node.js 22+ is needed for preview tests. Select the active
Xcode tools with `xcode-select`; check `xcrun swiftc --version` and `cmake --version`.
Tests need Pillow, reportlab and pypdf; install them in a Python virtual environment:

```sh
git clone https://github.com/double-u-zw/Ecru.git
cd Ecru
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r Tests/requirements.txt
zsh Scripts/build.sh
open ".build/apps/Ecru Dev.app"
```

The default builds **Ecru Dev** for the **host architecture**, into
`.build/apps/Ecru Dev.app`. App bundles stay in the hidden build workspace and are not automatically registered
as installed applications. It does not install or replace the daily Ecru application. Set `ECRU_ARCH=arm64` or
`ECRU_ARCH=x86_64` to choose explicitly. Each native dependency is built separately
into `.build/native-ink/<architecture>/`. Swift, C++ and dependencies target macOS
13.0. Running x86_64 executables/tests on Apple Silicon requires Rosetta 2.

Release distribution uses separate **arm64** and **x86_64** DMGs. To build both
from one checkout, `Scripts/build-release.sh` builds the host first, reuses its
native configuration receipt for the cross build, and packages two independent
Apps. Cross compilation does not require an emulator. The optional
`Scripts/build-universal.sh` remains available for developers who need Universal 2;
it is not used for the beta.4 downloads.

The first build downloads pinned Abseil, QPDF 12.4.2, libjpeg-turbo 3.2.0 and build-time GoogleTest configuration
from their public upstream repositories. QPDF and JPEG source archives are pinned
by full commit and SHA-256, without downloading their development histories. Google Ink, Stroke Modeler and the
perfect-freehand reference are vendored; offline preview assets are in Resources.
QPDF uses its native crypto backend and macOS system zlib; OpenSSL, GnuTLS and Homebrew native libraries are not required. There is no runtime network dependency. Do not use paths outside the checkout.

## Tests

```sh
zsh Scripts/test.sh
zsh Scripts/test.sh --ui
ECRU_ARCH=x86_64 zsh Scripts/test.sh
ECRU_ARCH=x86_64 zsh Scripts/test.sh --ui
zsh Scripts/test-image-performance.sh
zsh Scripts/test-laser.sh
```

Default tests use synthetic PDF fixtures and isolated recovery directories.
They cover geometry, native input lifecycle, saved PDF integrity, old annotations,
recovery, external conflicts and Markdown rendering. UI tests activate their own
window: run one at a time. They cover tools, editing, saving/reopening, long names,
light/dark appearance and widths 820/1160/1440. Physical input latency, mixed-DPI
multi-monitor behavior and actual macOS 13 hardware need separate human checks.
Personal recorded handwriting and old research experiments are excluded.
See [validation results](docs/Validation.md) for the tested environments.

## Distribution

```sh
ECRU_RELEASE_DOCS="$PWD" zsh Scripts/build-release.sh
```

Output: `output/releases/<EcruReleaseVersion>/Ecru-<version>-arm64.dmg` and
`Ecru-<version>-x86_64.dmg`,
installation notes, release notes and SHA-256 checksums. `Scripts/Info.plist` owns
App/release versions; native runtime metadata must match them. The shared checksum
file lists both DMGs; users downloading one can verify it with
`shasum -a 256 -c SHA256SUMS.txt --ignore-missing`. The release archive
contains LICENSE, NOTICE and all third-party texts. Signing is currently ad hoc;
Developer ID and Apple notarization require the maintainer's credentials.

`.github/workflows/build.yml` builds and tests on Apple Silicon and Intel runners,
and uploads the runner architecture DMG as a workflow artifact. It does not publish Releases.
Release scripts explicitly select `ECRU_VARIANT=release` and only produce candidate
artifacts in the checkout. To build one release App, run
`ECRU_VARIANT=release ECRU_RELEASE=1 zsh Scripts/build.sh`. The build script refuses
to write directly to the installed Ecru in /Applications or ~/Applications. Review
the development build first; update the daily App only after maintainer acceptance.

An accepted release is published with `Scripts/publish-release.sh` after UI review.
Existing published release assets and tags must never be replaced. Run `python3 Scripts/verify-release.py output/releases/0.5.0-beta.4` before publication.

## Keep development and release apps together

```sh
zsh Scripts/build.sh
open ".build/apps/Ecru Dev.app"
```

This creates **Ecru Dev**, with bundle ID `local.ecru.reader.development`,
separate preferences/recent documents and `Application Support/Ecru-Dev` drafts
and reading positions. It can be installed alongside **Ecru** (currently the public Beta, not a stable release). Release builds
retain the historical bundle ID and data location so existing recovery records
remain available. Neither build automatically copies the other application's data.
`ECRU_DATA_DIR`, when explicitly set for tests, overrides either data location.
Avoid editing the same PDF in both apps at once; use a copy for development.
