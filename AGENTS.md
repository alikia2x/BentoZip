# AGENTS.md

## Project Overview

BentoZip is a macOS compression/decompression app with a Finder-like UI. Users can drag files or directories into the window to compress them, or open/drag archive files to browse and extract their contents. The app supports creating ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ archives, and browsing/extracting additional read-only formats including GZIP, BZ2, XZ, and RAR.

## Architecture

### Mode-Based UI

The app has three modes (`ArchiveMode`) controlled by `AppState.mode`:

| Mode | Trigger | Behavior |
|---|---|---|
| `.empty` | App launch or reset | Shows `EmptyStateView` with drop target, file/archive open buttons, and recent archives |
| `.compress` | Dragging or selecting local files/directories | Shows file list, breadcrumbs, and status bar; right inspector for compression settings; toolbar compress button active |
| `.browseArchive` | Opening or dragging an archive file | Shows archive contents list; toolbar extract actions active; supports drag-out extraction, Quick Look, and writable archive mutations |

### State Management

- `AppState` (`@Observable`, `@MainActor`) is the single source of truth for window state. Passed via `.environment()` through the SwiftUI view hierarchy.
- `ProgressState` (`@Observable`, `@MainActor`) tracks operation progress, active filename, and cancellation state for the singleton progress window.
- `AppPreferences` uses SwiftData (`@Model`) managed by `PreferencesManager` for persistent user preferences.

### Compression/Extraction Engine Chain

```
CompressionCoordinator
  └── Bento7zEngine (JSONL subprocess client for bundled `bento7z` + `7z.so`)

All engines conform to ArchiveEngine protocol:
  listArchive(), listEntries(), extract(), create(), removeEntries(), addEntries()
```

### Key Design Decisions

1. **FileEntry is a tree**: `FileEntry.children` allows directory navigation. `ArchiveTreeBuilder` converts flat archive entries into hierarchical trees while rejecting path traversal segments.
2. **Single top-directory unwrapping**: Archives with a single top-level directory can automatically unwrap it when configured (`AppPreferences.unwrapSingleTopDirectory`).
3. **Atomic archive mutations**: `removeEntries` and `addEntries` use extract-then-rebuild with atomic file replacement and rollback on failure.
4. **Bundled `bento7z` helper**: `bento7z` and `7z.so` from the sibling `../bento7z/build/` project are copied and code-signed into `BentoZip.app/Contents/Helpers/` during the Xcode build phase.
5. **Progress window is a singleton `Window`**: Declared as `Window("进度", id: "progress")` and opened via `openWindow(id: "progress")` during operations.

### Drag and Drop & Quick Look

- **Drop-in**: `EmptyStateView` and `ContentView` route dropped URLs via `AppState.isArchiveDrop(_:)` / `AppState.handleDroppedURLs(_:)` (browse archive or add to compress list / writable archive).
- **Drag-out & Quick Look**: `DragDropManager` performs selective single-entry extraction into a session temp folder on drag-out or Quick Look preview, propagating password/error states when needed.

## Setup & Build

### Prerequisites

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+
- Sibling `../bento7z` built (`cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`)

### Build Commands

```bash
# Open in Xcode
open BentoZip.xcodeproj

# Build from command line (copies & signs bento7z + 7z.so into Contents/Helpers/)
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug build

# Run unit tests
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug -only-testing:BentoZipTests test

# Build the core Swift Package independently
cd BentoZipCore && swift build
```

## Code Style & Conventions

### General

- **Swift 5.9+** with SwiftUI (no AppKit unless unavoidable, e.g., `NSSavePanel`, `NSOpenPanel`, `QLPreviewPanel`)
- macOS 14+ deployment target
- All UI state must be `@MainActor`
- Use `@Observable` (Observation framework) over `@ObservableObject` / `@StateObject`

### Project Modules

- **BentoZip** (app target) → SwiftUI views and view-only helpers (`QuickLookHelper`). Never put business logic here.
- **BentoZipCore** (SPM package) → All models, services, utilities, and view models. Imported as `import BentoZipCore`.
- When adding new functionality: models/service logic → `BentoZipCore`; UI components → `BentoZip/Views/`.

### File Organization

- Views grouped by feature under `BentoZip/Views/<Feature>/`
- Core sources grouped by role under `BentoZipCore/Sources/BentoZipCore/<Models|ViewModels|Services|Utilities>/`
- Test files mirror the source structure under `BentoZipTests/`

### Naming

- `AppState` and `ProgressState` use `@Observable` → prefer `@Bindable var` in views for SwiftUI bindings.
- Archive engines implement `ArchiveEngine` protocol.

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
| `BentoZipApp.swift` | App entry point, SwiftData container, singleton progress window & Settings scene |
| `ContentView.swift` | Root view, mode switching, drop handling, password sheet |
| `AppState.swift` | Central state: entries, navigation, mode, settings, password prompt & recent archives |
| `Coordinator.swift` | `CompressionCoordinator`: orchestrates compress/extract/browse/mutate workflows & cancellation |
| `ArchiveEngine.swift` | Protocol all compression engines implement |
| `Bento7zEngine.swift` | `bento7z` JSONL subprocess engine with cancellation and path validation |
| `FormatDetector.swift` | Extension + magic-byte detection (`ReadableArchiveFormat` / `ArchiveFormat`) |
| `ArchiveTreeBuilder.swift` | Converts flat archive entries → navigable tree with path traversal filtering |

## Guardrails

- Never add business logic to `BentoZip/` views — delegate to `AppState`, `CompressionCoordinator`, `DragDropManager`, or `PreferencesManager`
- Avoid `try!` except in the known fallback pattern in `BentoZipApp.createModelContainer()`
- Never block `@MainActor` with synchronous directory walks or `Process.waitUntilExit()`
- Don't introduce new third-party dependencies without discussion
