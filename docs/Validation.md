# beta.2 development update

Current source: **0.5.0-beta.2-rc.2 (14)**. The prior RC1 artifacts and tag remain
unchanged. This update aligns the three reading-toolbar controls, follows the
viewport for the page indicator, and adds the optional isolated Ecru Dev build.
Local arm64 and Rosetta x86_64 UI runs each passed 59 checks on macOS 27.0.1
(one connected display). UI regression additionally covers scrolling to the last/first page and
jumping pages, with explicit vertical-centering checks across window sizes and
appearances. Development installation uses a distinct bundle ID and data folder.
The complete RC1 cross-platform baseline is recorded below.

## RC1 candidate validation

Candidate: **0.5.0-beta.2-rc.1 (13)**. Validation date: 2026-10-11.

| Environment | Result |
| --- | --- |
| Apple Silicon / macOS 27.0.1 | arm64 build, core regressions and 57 native UI checks passed |
| x86_64 through Rosetta 2 / macOS 27.0.1 | x86_64 build, core regressions and 57 native UI checks passed |
| Native arm64 / GitHub macOS 14 runner | Build and complete core regressions passed |
| Native x86_64 / GitHub macOS 15 Intel runner | Build and complete core regressions passed |
| Public GitHub clone, without private paths or dependency caches | Both dependency graphs fetched and built successfully |
| Separate distribution packages | Independent arm64 and x86_64 Apps/DMGs; deployment target 13.0 |

Cloud run: [both native architectures](https://github.com/double-u-zw/Ecru/actions/runs/38149987433),
source commit `2dd0745`. The final candidate documentation commit uses this same
application source.

Core tests cover 44 native input lifecycle cases, 128 ink geometry/PDF round trips,
142 save/recovery/conflict checks, 42 annotation checks, 23 geometry/cache checks,
pixel damage comparison, branding/input boundaries and 19 offline preview checks.
UI checks cover all six tools, undo/redo, eraser splitting, lasso movement,
Markdown/math note editing, search, Save As and reopening editable PDF annotations.
Zoom checks include presets, continuous magnification, fit page/width and a bounded
menu after 120 updates. The PadInk bridge additionally passed 11 local event checks.

Layout checks cover Aqua/Dark Aqua at 820, 1160 and 1440 points, long filenames
and both available displays (backing scale 2). The retained internal interface
suite also passed 134 checks covering tool parameters, sidebars and note cards.
The published screenshots are actual candidate windows using synthetic PDFs.

The Google Ink position-model digest remains
`72c5687901ca5e19cc66b9918412b6fd921869a8d9671710ccc506e179b0abfe`;
the recipe remains `google-ink-daily-v5`.

Physical Intel pen/trackpad interaction, macOS 13 hardware, mixed-DPI displays and device-specific
handwriting latency remain separate human checks. Automated events do not measure
physical pen latency. Ad-hoc signing is verified; Developer ID/notarization is
not available. Final beta.2 publication waits for UI acceptance.
