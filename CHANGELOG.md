# Changelog

All notable changes to BentoZip are documented in this file.

## [Unreleased]

## [1.0.0] - 2026-11-27

### Added
- **Finder-Native Workspace**: `NSOutlineView` list view and adaptive `FinderGridView` icon view with column visibility toggles (Date Modified, Size, Packed, Ratio, CRC32, Kind), path breadcrumbs, live toolbar search, Quick Look (`Space`), and drag-in / drag-out file promises.
- **Wide Format Creation & Extraction**: Create ZIP (AES-256 / ZipCrypto), 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, TAR.ZST, Zstd (`.zst`), Apple Archive (`.aar`), HFS+ `.dmg`, and multi-volume split archives; browse and extract GZIP, BZ2, XZ, ZSTD, RAR, DMG, ISO, XAR/PKG, CAB, WIM, CPIO, LZMA, DEB, RPM, LZH/LHA, SquashFS, VMDK, CHM, ARJ, LZ4, Brotli, EPUB/CBZ/CBR, and split volumes.
- **Bundled `bento7z` Engine & Caching**: Persistent `bento7z --server` binary Unix-socket worker with JSONL fallback, native in-place mutations (add, remove, rename, new folder, password update) for ZIP/7z/TAR, automatic CJK legacy filename encoding recovery, and LRU disk caching for compound `.tar.*` archives.
- **Nested Archives & Live Edit Save-Back**: Drill down into archives nested inside archives and automatically re-pack modified entries back into writable archives after external editing.
- **Presets, Vault & Image Gallery**: Reusable compression presets, batch archive operations, macOS Keychain password vault with Touch ID unlock, inline text/image preview, and archive image gallery sheet.
- **System Integration & Automation**: Shortcuts App Intents (`CompressFilesIntent`, `ExtractArchiveIntent`, `ListArchiveIntent`), `bentozip` CLI wrapper installer, macOS Services (`NSServices`), Quick Look preview extension, Finder Sync extension, Spotlight importer extension, and GitHub Releases self-updater.

### Changed
- Universal macOS (`arm64` + `x86_64`) build pipeline with inside-out Developer ID code signing across helpers and sandboxed app extensions.
- Custom trailing inspector drawer with smooth width animation, draggable 240–400 pt resize divider, and zero left-pane shifting.

### Fixed
- Secured custom `bentozip://` URL routing with absolute-path enforcement, action allowlisting, per-user IPC token verification, and confirmation fallback.
- Prevented column overflow and re-entrant `NSOutlineView` layout passes during window and inspector resizing.
