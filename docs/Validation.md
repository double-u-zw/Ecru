# beta.2 candidate validation

Candidate: **0.5.0-beta.2-rc.1 (13)**. Validation date: 2026-10-11.

| Environment | Result |
| --- | --- |
| Apple Silicon / macOS 27.0.1 | Universal build, core regressions and 52 native UI checks passed |
| x86_64 through Rosetta 2 / macOS 27.0.1 | Core regressions and 52 native UI checks passed |
| Public GitHub clone, without private paths or dependency caches | Both dependency graphs fetched and built successfully |
| Universal executable | arm64 + x86_64; both Mach-O deployment targets are 13.0 |

Core tests cover 44 native input lifecycle cases, 128 ink geometry/PDF round trips,
142 save/recovery/conflict checks, 41 annotation checks, 23 geometry/cache checks,
pixel damage comparison, branding/input boundaries and 19 offline preview checks.
UI checks cover all six tools, undo/redo, eraser splitting, lasso movement,
Markdown/math note editing, search, Save As and reopening editable PDF annotations.

Layout checks cover Aqua/Dark Aqua at 820, 1160 and 1440 points, long filenames
and both available displays (backing scale 2). The retained internal interface
suite also passed 134 checks covering tool parameters, sidebars and note cards.
The published screenshots are actual candidate windows using synthetic PDFs.

The Google Ink position-model digest remains
`72c5687901ca5e19cc66b9918412b6fd921869a8d9671710ccc506e179b0abfe`;
the recipe remains `google-ink-daily-v5`.

Physical Intel input, macOS 13 hardware, mixed-DPI displays and device-specific
handwriting latency remain separate human checks. Automated events do not measure
physical pen latency. Ad-hoc signing is verified; Developer ID/notarization is
not available. Final beta.2 publication waits for UI acceptance.
