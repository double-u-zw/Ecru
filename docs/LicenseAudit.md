# License and source publication audit

Ecru first-party code is published with the owner's authorization to permit
modification and derivative distributions. Apache-2.0 matches that intent and
provides an explicit contributor patent grant. LICENSE and NOTICE cover the
first-party project, with exceptions for separately attributed components.

Google Ink, Stroke Modeler and Abseil retain Apache-2.0, pinned by full upstream
commit. One documented Google Ink version-query qualification fixes older
Apple Clang lookup without changing its calculation or stroke behavior. The
selected upstream revisions have no separate root NOTICE file.
perfect-freehand (including its attributed Swift port), markdown-it, texmath and
KaTeX retain MIT notices. KaTeX font files retain SIL OFL 1.1, font copyrights and
Reserved Font Names; they are not relicensed as Apache or MIT. Apple frameworks
come from macOS and are not redistributed. GoogleTest is build-time-only.

No included dependency requires Ecru's own code to use a different license.
The MIT notices are retained with the derived/included material. OFL applies to
the included font software, while allowing it to be bundled with the application.
Original project artwork and synthetic sample text are included under Apache-2.0.

Primary license guidance:
- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
- [Apache licensing FAQ](https://www.apache.org/foundation/license-faq.html)
- [ASF third-party license policy (MIT category A)](https://www.apache.org/legal/resolved.html)
- [SIL OFL FAQ (software bundles)](https://openfontlicense.org/ofl-faq/)

The public source is exported by an explicit list from the current development
checkout, not by pushing its Git history. It excludes personal handwriting traces,
old experiments, diagnostics, caches, local output and private project notes.
Public tests use generated PDFs. The old-format compatibility fixture preserves
three schema-1 stroke payloads on original sample text, without the old annotation
author, Apple editor metadata or embedded system fonts. Both published PDFs use
standard base-14 fonts. Preview fonts are separately licensed KaTeX distributions.

Plaintext scans check personal absolute paths, private-key headers and common
credential patterns. PDF metadata and annotation dictionaries are checked as well.
These checks describe the actual export, rather than changing user documents.
The historical beta.1 tag and Release assets are retained byte-for-byte.
