# Ecru 0.5.0-beta.2-rc.1 (13)

Candidate for beta.2; the public beta.1 download remains unchanged.

- One centered filename in the compact document toolbar; no persistent version
  subtitle. Navigation stays left; page, zoom and search controls stay right.
- Long filenames truncate in place, including after Save As. Native window menus,
  represented file URL, edited indication and filename/Finder interaction remain.
- Fix safe-save false rejections when older PDFKit reorders extracted text runs;
  original drawing streams, page geometry and annotations remain validated.
- Apache-2.0 source published with build instructions, tests and third-party texts.
- Separate arm64 and x86_64 DMGs for Apple Silicon and Intel, macOS 13+.
- Current Google Ink recipe and position model are unchanged; cursor-free pen
  input and the page-local eraser experience are preserved.

Validation covers core PDF save/recovery/legacy compatibility, native tool editing,
light/dark windows and multiple sizes. Intel is initially checked through Rosetta;
physical Intel hardware, macOS 13 and mixed-DPI monitors remain human checks.
This candidate is ad-hoc signed and not notarized. No automatic update or OCR.
UI acceptance is required before publishing the beta.2 Release.

- 保存时保留原 PDF 页面绘图流和字体/图片资源，兼容较旧 macOS 的 PDFKit 批注导出。
