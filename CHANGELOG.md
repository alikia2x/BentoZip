# Changelog

All notable changes to BentoZip are documented in this file.

## [Unreleased]

## [1.0]

### Added
- Native macOS archive manager with a Finder-like `NSOutlineView` file browser, breadcrumbs, column sorting, Quick Look preview, and drag-and-drop compression and extraction.
- Archive creation for ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ, plus read-only browsing and extraction for GZIP, BZ2, XZ, and RAR.
- Bundled `bento7z` + `7z.so` engine with a binary Unix-socket server, in-place archive mutations for ZIP/7z/TAR, and persistent disk caching for compound `.tar.*` archives.
- Multi-window document routing, standalone cross-window transfer progress window, password prompt handling, and persistent user preferences.
