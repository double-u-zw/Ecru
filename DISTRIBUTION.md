# Ecru distribution and source

This repository contains buildable Ecru source and public Beta distribution materials.
First-party code, documentation and artwork are licensed under Apache-2.0; see LICENSE
and NOTICE. Third-party materials retain their licenses in THIRD_PARTY_NOTICES.md,
licenses/ and their source directories. The private development Git history is not imported.

Beta 3 targets macOS 13+ on Apple Silicon and Intel through independent arm64 and
x86_64 App/DMG builds. Its source tag identifies the frozen public source used by both
packages. Historical Beta 1, Beta 2, RC tags and installation packages are immutable.
Release preparation creates local candidates; preparing a package does not publish a Release.

Signing is ad hoc. Apple Developer ID signing and notarization are not available.
The default development build remains Ecru Dev, with separate identity, preferences
and recovery storage. Release builds do not install themselves or replace the daily App.
