# AGENTS.md

## Project Overview

BentoZip is a macOS compression/decompression app with a Finder-like UI. Users can drag files or directories into the window to compress them, or drag archive files to browse and extract their contents. The app supports ZIP, 7z, and tar.gz formats.

## Architecture

### Mode-Based UI

The app has three modes (`ArchiveMode`) controlled by `AppState.mode`:

| Mode | Trigger | Behavior |
|---|---|---|
| `.empty` | App launch or reset | Shows `EmptyStateView` with drop target; accepts files or archives |
| `.compress` | Dragging in files/directories | Shows file list + breadcrumbs; right sidebar for compression settings; toolbar compress button active |
| `.browseArchive` | Dragging in an archive file | Shows archive contents list; toolbar extract button active; can drag entries out to extract |

### State Management

- `AppState` (`@Observable`, `@MainActor`) is the single source of truth. Passed via `.environment()` through the SwiftUI view hierarchy.
- `ProgressState` (`@Observable`, `@MainActor`) tracks operation progress for the progress window.
- `AppPreferences` uses SwiftData (`@Model`) for persistent user preferences.

### Compression/Extraction Engine Chain

```
CompressionCoordinator
  ├── ZIPEngine (ZIPFoundation-based) — ZIP format
  └── LibArchiveWriter (libarchive-based) — 7z, tar.gz formats
  └── LibArchiveReader (libarchive-based) — reads ZIP, 7z, tar.gz

All engines conform to ArchiveEngine protocol:
  listEntries(), extract(), create(), removeEntries(), addEntries()
```

### Key Design Decisions

1. **FileEntry is a tree**: `FileEntry.children` allows directory navigation. `ArchiveTreeBuilder` converts flat archive entries into hierarchical trees.
2. **Single top-directory unwrapping**: Archives with a single top-level directory automatically skip it (see `ArchiveTreeBuilder.unwrapSingleDirectory()` and `CompressionCoordinator.unwrapSingleTopDirectory()`).
3. **Atomic archive mutations**: `removeEntries` and `addEntries` use extract-then-rebuild with atomic file replacement and rollback on failure.
4. **ZIP vs libarchive split**: ZIP uses ZIPFoundation for efficiency; 7z/tar.gz uses libarchive. Format detection by both extension and magic bytes.
5. **Progress window is a separate `WindowGroup`**: Opened via `openWindow(id: "progress")` during operations.

### Drag and Drop

- **Drop-in (compress)**: `EmptyStateView` accepts `URL` drops; detects if it's an archive (→ browse) or files (→ compress). `ContentView` also accepts drops in compress mode.
- **Drag-out (extract)**: `DragDropManager` extracts archive entries to temp directory on drag, then provides the temp file URL.

## Setup & Build

### Prerequisites

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

### Build Commands

```bash
# Open in Xcode
open BentoZip.xcodeproj

# Build from command line
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug build

# Run tests
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug test

# Build the core Swift Package independently
cd BentoZipCore && swift build
```

### Dependencies (resolved automatically via SPM)

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation.git) `>= 0.9.0` — ZIP format support
- [libarchive-for-swift](https://github.com/matteo-pacini/libarchive-for-swift.git) `>= 1.0.0` — 7z/tar.gz support

## Code Style & Conventions

### General

- **Swift 5.9+** with SwiftUI (no AppKit unless unavoidable, e.g., `NSSavePanel`)
- macOS 14+ deployment target
- All UI state must be `@MainActor`
- Use `@Observable` (Observation framework) over `@ObservableObject` / `@StateObject`

### Project Modules

- **BentoZip** (app target) → SwiftUI views only. Never put business logic here.
- **BentoZipCore** (SPM package) → All models, services, utilities, and view models. Imported as `import BentoZipCore`.
- When adding new functionality: models/service logic → `BentoZipCore`; UI components → `BentoZip/Views/`.

### File Organization

- Views grouped by feature under `BentoZip/Views/<Feature>/`
- Core sources grouped by role under `BentoZipCore/Sources/BentoZipCore/<Models|ViewModels|Services|Utilities>/`
- Test files mirror the source structure under `BentoZipTests/`

### Naming

- `AppState` and `ProgressState` use `@Observable` → prefer `@Bindable var` in views for SwiftUI bindings.
- Archive engines implement `ArchiveEngine` protocol; each format gets its own struct.

### Error Handling

- Use Swift `LocalizedError` for domain errors (see `ReaderError`, `ArchiveWriterError`)
- `AppState.lastError` propagates errors to UI alerts
- Never use `try!` outside of `createModelContainer()` fallback (where crashing is intentional if in-memory fallback also fails)

### Testing

- Tests use `XCTest` framework
- Test files: `*Tests.swift` in `BentoZipTests/`
- Always add tests for new engine operations (compress, extract, list, add, remove)
- UI tests in `BentoZipUITests/`

## Key Files to Know

| File | Purpose |
|---|---|
| `BentoZipApp.swift` | App entry point, SwiftData container, progress window declaration |
| `ContentView.swift` | Root view, mode switching, drop handling |
| `AppState.swift` | Central state: entries, navigation, mode, settings |
| `CompressionCoordinator.swift` | Orchestrates compress/extract workflows (save panels, engine selection, progress) |
| `ArchiveEngine.swift` | Protocol all compression engines must implement |
| `ZIPEngine.swift` | ZIP compression via ZIPFoundation |
| `LibArchiveWriter.swift` | 7z/tar.gz compression via libarchive (largest file, ~830 lines) |
| `LibArchiveReader.swift` | Archive reading for all formats via libarchive |
| `ArchiveTreeBuilder.swift` | Converts flat archive entries → navigable tree |

## Common Patterns

### Adding a new archive format

1. Add a case to `ArchiveFormat` enum in `CompressionSettings.swift`
2. Add format/filter configuration in `LibArchiveWriter` (`configureFormat` / `configureFilter`)
3. Add format detection in `FormatDetector` (extension + magic bytes)
4. Add UI label update if needed

### Adding a new toolbar action

1. Add the state/logic to `AppState` (if state changes) or `CompressionCoordinator` (if async work)
2. Add the button to `ToolbarCommands.swift`
3. Use `disabled()` modifier to gate on the correct `ArchiveMode`

### Adding a new setting

1. Add the property to `CompressionSettings`
2. Add UI in `CompressionSettingsView`
3. If it should persist, add to `AppPreferences` and update `PreferencesManager`

## Guardrails

- Never add business logic to `BentoZip/` views — delegate to `AppState` or `CompressionCoordinator`
- Avoid `try!` except in the known fallback pattern in `BentoZipApp.createModelContainer()`
- Keep `LibArchiveWriter.swift` simple — extract helpers to new files if needed
- Don't introduce new third-party dependencies without discussion
- When working with libarchive, always pair `archive_read_new()` with `archive_read_free()` in a `defer` block
