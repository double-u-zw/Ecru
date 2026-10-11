# Google Ink C++ core

Source: https://github.com/google/ink
Commit: b6def591a73a6aa0ffce1e58dc69b39de31484ba
License: Apache-2.0 (LICENSE, included in the app).

This is the source/header closure of the upstream Bazel target
`//ink/strokes:in_progress_stroke`, excluding Abseil. `sources.cmake` enumerates
its translation units. No Android, JNI, rendering, Skia, Dawn, protobuf/storage,
stock brush, benchmark, or test targets are compiled into Ecru.

macOS adaptation: Sources/Native/CMakeLists.txt uses C++20, Apple Clang, deployment
target macOS 13, and statically linked Abseil 20260526.0, pinned to commit
5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a. A narrowly scoped Apple Clang compatibility patch is documented below.
The hand-written C ABI, daily brush definition and Core Graphics outline adapter
are Ecru code, outside this vendor directory. Upstream API stability is not
promised; update the pinned closure and run the regressions together.

The older independent ink-stroke-modeler vendor remains for historical regression
executables. It is not the production pen's input model or brush generator.

## Ecru 0.5 (8) input response

Brush geometry and input algorithms remain upstream-original. Ecru models position once
in `Sources/Native/AdaptivePositionModel.h`, then supplies the result to upstream
`PassthroughModel`. Brush behavior, shape generation and geometry are unchanged.
The new filter is Ecru code inspired by the 1 Euro paper:
https://gery.casiez.net/publications/CHI2012-casiez.pdf

## Apple Clang compatibility patch (beta.2)

`ink/brush/brush_paint.cc` gives its two anonymous texture-version helpers distinct
names and removes their using-declaration. Older Apple Clang otherwise reports
ambiguous lookup between a header declaration and its implementation. Only helper
names and lookup change; all calculations, input, brush and geometry behavior are
unchanged. The file carries an Ecru modification notice. All other vendored files
retain the pinned upstream content.
