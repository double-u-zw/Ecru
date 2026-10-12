# Beta 3 validation results

Candidate identity: **0.5.0-beta.3 (19)**. The application functionality is the accepted
Ecru Dev Build 18 baseline. Build 19 freezes release identity and distribution materials;
Google Ink recipe and AdaptivePositionModel remain unchanged.

## Accepted feature baseline

- 78 image/fill checks: clipboard formats, transparent images, non-destructive crop,
  movement/resize/rotation, mixed groups, locking, undo/redo, two save/reopen rounds,
  original source deletion, recovery, read-only protection and legacy shape appearance.
- Independent PDF inspection: full source pixel dimensions, lossless RGB, exact alpha,
  standard image appearance streams and preserved original selectable text.
- 33 native UI checks: six-tool behavior, native text-field/editor paste routing,
  image insertion, compact window sizes, crop cancellation and return to the prior tool.
- 218 complex PDF cases, 32 independent original-structure checks and 64 native
  compatibility checks. Plain forms/attachments remain intact; signed/encrypted and
  active-content documents retain their applicable protections.
- Local arm64 and Rosetta x86_64 image, writing and input-lifecycle regressions.
- Actual macOS Preview display of embedded images, transparency, ink and shape fills.
- Maintainer UI acceptance of Build 18 on 2026-10-13.

## Release preparation

Run the self-contained public regressions from the frozen export on both architecture
paths; no private handwriting recordings or user PDFs are needed. The image suite is
part of `Scripts/test.sh`, and can also run through `Scripts/test-image-objects.sh`.

`Scripts/verify-release.py output/releases/0.5.0-beta.3` verifies both DMG checksums,
read-only mounts, every file in the copied App, architecture, deployment target,
system-only dynamic libraries, exact frozen source revision, metadata, native model
receipt, strict ad-hoc signature and complete third-party licenses. Its final evidence
is `verification.json` alongside the release packages. Verification never installs
an App, registers verification copies or changes user documents/recovery records.

## Native CI and published release

The [Beta 3 native CI run](https://github.com/double-u-zw/Ecru/actions/runs/38276748166)
passed on macOS 14 Apple Silicon and macOS 15 Intel, with builds, complete public core
regressions, 78 image/fill checks and two independent lossless PDF appearances per
architecture, and DMG packaging. Both native artifacts passed checksum verification.

The [published Beta 3 release](https://github.com/double-u-zw/Ecru/releases/tag/v0.5.0-beta.3)
pins source `9231496b9dadc5ca5e5341fdcb3795246ce9bf08`; both distributed Apps embed
that source revision. All five uploaded release assets were downloaded and compared
byte-for-byte with the verified local files before publication. The old releases,
asset identities and digests, and annotated/peeled historical tag refs were preserved.

Subsequent documentation updates do not alter the frozen release source or assets.
Physical Intel input, macOS 13 hardware, HDR-source behavior, mixed-DPI displays and
long-duration writing remain separate checks.
Automated rendering benchmarks do not measure physical pen latency.
