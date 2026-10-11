# Handwriting implementation

The production recipe is `google-ink-daily-v5`. `HandwritingEngine.swift` passes
native event position/time/pressure and the PDF display scale to the C ABI in
`Native/GoogleInkBridge.cc`. Ecru's AdaptivePositionModel models position once;
Google Ink's PassthroughModel, InProgressStroke and brush generate outlines.
Core Graphics paints those outlines through PageInkPresentation.

The frozen position-model SHA-256 is
`72c5687901ca5e19cc66b9918412b6fd921869a8d9671710ccc506e179b0abfe`.
The linked native archive exports its parameters and revision into the App;
build scripts verify that model digest, recipe and version match. The arm64 and x86_64 builds
use the same source and parameter file, with independent native archives.

Saved outlines are authoritative and are not regenerated when old PDFs reopen.
Legacy Perfect/Observation paths support historical stroke representations;
they are not additional selectable production engines. Cursor-free pen behavior
and the page-local eraser are intentional. UI test event fabrication is excluded
from production by compile flags. See Architecture.md for storage/data contracts.
