# Ecru 0.5.0-beta.2-rc.2 (14)

Candidate for beta.2; the public beta.1 download remains unchanged.

- Align navigation icons and page-number baselines with native stack layout.
  Keep the page indicator synchronized with continuous scrolling and page jumps.
- Add an optional Ecru Dev build with independent application identity, preferences
  and recovery storage, so it can coexist with the installed release.
- One centered filename in the compact document toolbar; no persistent version
  subtitle. Navigation stays left; page, zoom and search controls stay right.
- Long filenames truncate in place, including after Save As. Native window menus,
  represented file URL, edited indication and filename/Finder interaction remain.
- Keep the zoom menu bounded during repeated magnification; fit page/width and
  percentage presets remain directly accessible.
- Preserve original PDF drawing streams and font/image resources during saving.
  Handle older PDFKit text ordering, sub-millipoint geometry rounding and generated
  note popups without losing editable annotations.
- Apache-2.0 source published with build instructions, tests and third-party texts.
- Separate arm64 and x86_64 DMGs for Apple Silicon and Intel, macOS 13+.
- Current Google Ink recipe and position model are unchanged; cursor-free pen
  input and the page-local eraser experience are preserved.

Validation covers core PDF save/recovery/legacy compatibility, native tool editing,
light/dark windows and multiple sizes. Core regressions passed on native macOS 14
arm64 and macOS 15 Intel CI, as well as locally on arm64 and Rosetta. Physical Intel
pen/trackpad interaction, macOS 13 and mixed-DPI monitors remain human checks.
This candidate is ad-hoc signed and not notarized. No automatic update or OCR.
UI acceptance is required before publishing the beta.2 Release.
