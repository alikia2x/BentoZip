# AGENTS.md

## Project Overview

BentoZip is a macOS compression and decompression app with a Finder-like UI. Users can drag files or directories into the window to compress them, or open/drag archive files to browse and extract their contents. The app supports creating ZIP (AES-256 / ZipCrypto), 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, and Apple Archive (`.aar`) archives (including multi-volume split creation for ZIP and 7z), and browsing/extracting read-only formats including GZIP, BZ2, XZ, ZSTD (`.zst`, `.tar.zst`, `.tzst`), RAR, DMG, ISO, XAR/PKG, CAB, WIM, CPIO, LZMA, DEB, RPM, LZH, and split volumes.

## Monorepo Layout

- `BentoZip/`: macOS SwiftUI + AppKit application target (views and view-only helpers)
- `BentoZipCore/`: Core Swift Package (models, engines, coordinator, utilities, and `@Observable` view models)
- `BentoZipTests/`: Unit tests (Swift `Testing` and `XCTest`)
- `BentoZipUITests/`: macOS UI tests
- `engine/bento7z/`: Bundled C++17 `bento7z` engine (`bit7z` + `7z.so`, binary Unix-socket server, JSONL fallback, and CJK ZIP encoding recovery)
- `scripts/`: Local and CI helper scripts (`build-engine.sh`, `build-release.sh`, `create-dmg.sh`)
- `website/`: Astro + React + Tailwind landing page
- `docs/`: Product documentation including [docs/ROADMAP.md](docs/ROADMAP.md)

## Architecture

### Mode-Based UI

The app has three modes (`ArchiveMode`) controlled by `AppState.mode`:

| Mode | Trigger | Behavior |
|---|---|---|
| `.empty` | App launch or reset | Shows `EmptyStateView` with drop target, file/archive open buttons, and recent archives sidebar |
| `.compress` | Dragging or selecting local files/directories | Shows file list, breadcrumbs, and status bar; resizable right inspector (`CompressInspectorView`, 240-400 pt) for compression settings; toolbar compress button active |
| `.browseArchive` | Opening or dragging an archive file | Shows archive contents list; resizable right inspector (`ArchiveInfoInspectorView`, 240-400 pt) for archive metadata and extract actions; toolbar extract actions active; supports drag-out extraction, Quick Look, and writable archive mutations |

### State Management

- `AppState` (`@Observable`, `@MainActor`) is owned per window (`WindowRootView` inside `WindowGroup(id: "workspace", for: WorkspaceLaunchRequest.self)`) and passed via `.environment()` through that window's SwiftUI hierarchy.
- `DocumentWindowRouter` + `WindowDocumentBridge` coordinate native macOS Document-Based App behavior across windows (`NSWindow.representedURL` proxy icons, duplicate-archive deduplication, `File > New / Open / Open Recent` menu routing, and Finder double-click / Dock drop handling) while keeping the Welcome screen on cold launch.
- `TransferManager` (`@Observable`, `@MainActor`) tracks active compress/extract/mutate `TransferTask`s across all windows with live 7-Zip-style telemetry (elapsed/remaining time, speed, processed/total bytes, file count, compressed size/ratio) and drives the standalone macOS Progress window (`TransferWindowController` + `TransferWindowView`). `ProgressState` tracks per-window busy state for non-blocking re-entrancy protection.
- `AppPreferences` uses SwiftData (`@Model`) managed by a shared `PreferencesManager` for persistent user preferences.

### Compression/Extraction Engine Chain

```
CompressionCoordinator
  ├── Bento7zEngine (full-async binary Unix-socket client for bundled `bento7z --server` + `7z.so`, with JSONL stdio fallback)
  └── AppleArchiveEngine (native macOS `AppleArchive` / `Compression` backend for `.aar` and `.yaa`)

All primary archive workflows conform to ArchiveEngine (`Bento7zEngine` delegates `.aar` operations to `AppleArchiveEngine`):
  listArchive(), listEntries(), extract(), create(), removeEntries(), addEntries()
```

### Key Design Decisions

1. **Single-source-of-truth `FileNode` tree**: `FileNode` (`@MainActor final class`) holds `parent`/`children` references for O(1) incremental updates (background folder sizing and lazy 1-level directory expansion) and directly backs `NSOutlineView`. `ArchiveTreeBuilder` converts flat archive listings into hierarchical `FileEntry` trees while rejecting path traversal segments, which `AppState` materializes into `FileNode`s.
2. **Native Finder `NSOutlineView` file list**: `FinderOutlineView` + `FinderOutlineCoordinator` render both `.compress` and `.browseArchive` modes in a single unified outline view (toggling only `Packed` column visibility), with native blue selection, arrow/type-ahead navigation, responder-chain `QLPreviewPanelController` Quick Look, native drag-in, and `NSFilePromiseProvider` drag-out.
3. **Single top-directory unwrapping**: Archives with a single top-level directory can automatically unwrap it when configured (`AppPreferences.unwrapSingleTopDirectory`).
4. **Native in-place mutations & persistent disk cache**: ZIP, 7z, and TAR additions/deletions run natively in-place via `bento7z` (`BitArchiveEditor`), falling back to atomic extract-rebuild only for compound `.tar.*` / solid archives. Non-encrypted compound `.tar.gz`/`.tar.bz2`/`.tar.xz` (and `.tar.zst`) archives cache their unwrapped `.tar` under `~/Library/Caches` (`ArchiveCacheManager`) with configurable LRU quota, staleness validation, and real outer-stream progress reporting.
5. **Bundled `bento7z` helper**: `bento7z` and `7z.so` from `engine/bento7z/build/` (built via `./scripts/build-engine.sh`) are copied and code-signed into `BentoZip.app/Contents/Helpers/` during the Xcode build phase.
6. **Standalone macOS Progress window**: Operations register `TransferTask`s in `TransferManager.shared`, automatically opening `TransferWindowController`'s standalone native window (stacking concurrent tasks from multiple windows without blocking document browsing, with an expandable 7-Zip-style statistics drawer per task) and auto-closing when all tasks finish.
7. **CJK legacy ZIP encoding repair**: `engine/bento7z/src/zip_encoding.cpp` automatically detects and converts non-UTF-8 legacy ZIP entry names (e.g., GBK, Big5, Shift-JIS) via `iconv` across both listing and extraction.

### Drag and Drop & Quick Look

- **Drop-in**: `EmptyStateView`, `FinderOutlineView` (native `.fileURL` drop validation/acceptance), and `ContentView` route dropped URLs via `AppState.isArchiveDrop(_:)` / `AppState.handleDroppedURLs(_:)` (browse archive or add to compress list / writable archive).
- **Drag-out & Quick Look**: `FinderOutlineCoordinator` drags local items directly as `NSURL` and archive items lazily via `NSFilePromiseProvider`. `DragDropManager` extracts single entries into unique per-extraction temp subdirectories with metadata-keyed caching, and `QuickLookHelper` integrates with `FinderOutlineView`'s responder chain for live arrow-key preview switching.

## Setup & Build

### Prerequisites

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+
- CMake 3.20+ and Apple Clang for `engine/bento7z/` (built via `./scripts/build-engine.sh`)
- Node.js 22+ and pnpm 10+ (for `website/`, optional)

### Build Commands

```bash
# Build bundled bento7z + 7z.so into engine/bento7z/build/
./scripts/build-engine.sh

# Open in Xcode
open BentoZip.xcodeproj

# Build from command line (copies & signs bento7z + 7z.so into Contents/Helpers/)
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug build

# Run unit tests
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug -only-testing:BentoZipTests test

# Build the core Swift Package independently
cd BentoZipCore && swift build -Xswiftc -warnings-as-errors

# Website development & production build
pnpm --dir website dev
pnpm --dir website build
```

## Code Style & Conventions

### General

- **Swift 5.9+** with SwiftUI (AppKit where needed for native macOS fidelity, e.g., `NSOutlineView`, `NSSavePanel`, `NSOpenPanel`, `QLPreviewPanel`)
- macOS 14+ deployment target
- All UI state must be `@MainActor`
- Use `@Observable` (Observation framework) over `@ObservableObject` / `@StateObject`
- Avoid prohibited middle-dot (`U+00B7`) characters in `BentoZip/` and `BentoZipCore/` source files (enforced by CI)

### Project Modules

- **BentoZip** (app target) -> SwiftUI views and view-only helpers (`QuickLookHelper`). Never put business logic here.
- **BentoZipCore** (SPM package) -> All models, services, utilities, and view models. Imported as `import BentoZipCore`.
- When adding new functionality: models/service logic -> `BentoZipCore`; UI components -> `BentoZip/Views/`.

### File Organization

- Views grouped by feature under `BentoZip/Views/<Feature>/`
- Core sources grouped by role under `BentoZipCore/Sources/BentoZipCore/<Models|ViewModels|Services|Utilities>/`
- Test files mirror the source structure under `BentoZipTests/`

### Naming

- `AppState` and `ProgressState` use `@Observable` -> prefer `@Bindable var` in views for SwiftUI bindings.
- Archive engines implement `ArchiveEngine` protocol (`AppleArchiveEngine` is encapsulated behind `Bento7zEngine` for `.aar`/`.yaa`).

### Error Handling

- Use Swift `LocalizedError` for domain errors (see `Bento7zError`)
- `AppState.lastError` propagates errors to UI alerts; password errors trigger `PasswordPromptSheet` via `AppState.needsPasswordPrompt`
- Never use `try!` outside of `createModelContainer()` fallback (where crashing is intentional if in-memory fallback also fails)

### Testing

- Unit tests use Swift `Testing` (`@Suite`, `@Test`, `#expect`) and `XCTest` in `BentoZipTests/`
- Always add tests for new engine operations (compress, extract, list, add, remove, format detection, path safety)
- UI tests in `BentoZipUITests/`

## Key Files to Know

| File | Purpose |
|---|---|
| `BentoZipApp.swift` / `DocumentWindowRouter.swift` | App entry point, Document-Based multi-window routing, `NSWindow.representedURL`, File/Recent menus & Settings scene |
| `TransferManager.swift` / `TransferWindowController.swift` / `TransferWindowView.swift` | Cross-window transfer telemetry and standalone macOS Progress window with expandable 7-Zip-style stats drawer |
| `ContentView.swift` | Root view, mode switching, resizable inspector container, drop handling, password prompt sheet |
| `FinderOutlineView.swift` / `FinderOutlineCoordinator.swift` | Native AppKit Finder-style `NSOutlineView`, responder-chain Quick Look, sorting & drag-and-drop |
| `FileNode.swift` | Single-source-of-truth `@MainActor` reference tree node backing `AppState` and `NSOutlineView` |
| `AppState.swift` | Per-window central state: `FileNode` tree, incremental update log, navigation, mode, settings & recent archives |
| `Coordinator.swift` | `CompressionCoordinator`: orchestrates compress/extract/browse/mutate workflows & cancellation |
| `ArchiveEngine.swift` | Protocol primary archive engines implement |
| `Bento7zEngine.swift` / `Bento7zBinaryClient.swift` | `bento7z` multiplexed Unix-socket engine with JSONL stdio fallback, cancellation, and path validation |
| `AppleArchiveEngine.swift` | Native macOS `AppleArchive` / `Compression` backend for `.aar` and `.yaa` |
| `FormatDetector.swift` | Extension + magic-byte detection (`ReadableArchiveFormat` / `ArchiveFormat`) |
| `ArchiveTreeBuilder.swift` | Converts flat archive entries -> navigable tree with path traversal filtering |

## Guardrails

- Never add business logic to `BentoZip/` views — delegate to `AppState`, `CompressionCoordinator`, `DragDropManager`, or `PreferencesManager`
- Avoid `try!` except in the known fallback pattern in `BentoZipApp.createModelContainer()`
- Never block `@MainActor` with synchronous directory walks or `Process.waitUntilExit()`
- Don't introduce new third-party dependencies without discussion
