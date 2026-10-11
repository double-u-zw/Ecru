# Google Ink Stroke Modeler

Upstream: https://github.com/google/ink-stroke-modeler
Revision: f2388813b0b25bc3e33d143d369a8367ab2e30c8 (see REVISION).
License: Apache-2.0, reproduced in LICENSE and the application bundle.

The upstream ink_stroke_modeler/, cmake/, and CMakeLists.txt are unmodified.
Ecru's adapter and parameter choices live in Sources/Native, outside this tree.
Upstream CMake pins Abseil bc257a88f7c1939f24e0379f14a3589e926c950c
and googletest 52eb8108c5bdec04579160ae17225d66034bd723. The latter is
fetched by upstream configuration but not linked into Ecru. Abseil's license
is also bundled. The combined library is statically linked; there are no
runtime network requests or external shared-library requirements.
