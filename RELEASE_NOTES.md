# Ecru 0.5.0-beta.2 (15)

Native macOS UI refinements, open source and Intel support.

Download **arm64** for Apple Silicon (M series), or **x86_64** for Intel. Both
packages require macOS 13+ and contain the same features. Historical beta.1
remains available without changes.

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
This Beta is ad-hoc signed and not notarized. On first launch, use **System
Settings → Privacy & Security → Open Anyway** if macOS blocks the application.
No automatic update or OCR.

[Build instructions](https://github.com/double-u-zw/Ecru/blob/v0.5.0-beta.2/BUILDING.md) ·
[Known limitations and feedback](https://github.com/double-u-zw/Ecru#已知限制)
