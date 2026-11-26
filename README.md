# BentoZip

A native macOS archive manager built with SwiftUI, AppKit (`NSOutlineView` + Quick Look), and an embedded asynchronous C++17 `bento7z` engine (`bit7z` + `7z.so`).

BentoZip lets you browse archive contents like a Finder window, drag individual files out lazily without extracting an entire archive, inspect and edit writable archives in place, and run heavy compression or extraction jobs in a decoupled background Tasks window.

## Key Capabilities

- **Three-Mode Finder Workspace**: Welcome drop view (`.empty`), staging/configuration view (`.compress`), and archive browser (`.browseArchive`) with a unified `NSOutlineView`, column sorting, type-ahead navigation, breadcrumbs, and a resizable right inspector.
- **Writable Formats**: Create archives in **ZIP** (AES-256 or ZipCrypto), **7z** (with header encryption), **TAR**, **TAR.GZ**, **TAR.BZ2**, **TAR.XZ**, and **Apple Archive (`.aar`)**. Create multi-volume split archives (`10 MB` – `4 GB`) for ZIP and 7z.
- **In-Place Archive Editing**: Add or delete entries directly inside existing ZIP, 7z, and TAR archives via `BitArchiveEditor` (falling back to atomic extract-and-rebuild for solid 7z and compound `.tar.*` archives).
- **Read-Only Format Support**: Browse and extract **GZIP**, **BZ2**, **XZ**, **ZSTD** (`.zst`, `.tar.zst`, `.tzst`), **RAR**, **DMG**, **ISO**, **XAR / PKG**, **CAB**, **WIM**, **CPIO**, **LZMA**, **DEB**, **RPM**, **LZH**, and split volumes (`.7z.001`, `.zip.001`, `.tar.001`, `.partN.rar`, `.rNN`, `.001`).
- **Legacy CJK ZIP Filename Repair**: Automatically detects and converts non-UTF-8 legacy ZIP entry names (such as GBK, Big5, and Shift-JIS) during both listing and extraction.
- **High-Throughput Engine & Disk Cache**:
  - Multiplexed Unix Domain Socket client (`bento7z --server`) separating a persistent interactive worker from isolated heavy-task workers, with JSONL stdio fallback.
  - Persistent LRU disk cache under `~/Library/Caches` for unwrapped `.tar` streams of non-encrypted compound `.tar.*` archives (`Off`, `512 MB`, `1 GB`, `2 GB`, `4 GB` quota).
  - Native Document-Based multi-window routing and a standalone 7-Zip-style Tasks progress window.

## Monorepo Layout

```text
BentoZip/
├── BentoZip/                  # macOS SwiftUI + AppKit application target
├── BentoZipCore/              # Swift Package: models, engines, coordinator, and view models
├── BentoZipTests/             # Swift Testing & XCTest unit tests
├── BentoZipUITests/           # macOS UI tests
├── BentoZip.xcodeproj/        # Xcode project (bundles & codesigns bento7z + 7z.so)
├── engine/
│   └── bento7z/               # C++17 archive engine (bit7z + 7z.so)
├── website/                   # Astro + React + Tailwind landing page
└── scripts/                   # Build, DMG packaging, and release automation scripts
    ├── build-engine.sh
    ├── build-release.sh
    └── create-dmg.sh
```

## Development Prerequisites

- macOS 14.0+ (deployment target: macOS 14.0, currently targeting `arm64`)
- Xcode 15.0+ and Swift 5.9+
- CMake 3.20+, Ninja/Make, and Apple Clang (for `engine/bento7z`)
- Node.js 22+ and pnpm 10+ (for `website/`, optional)

## Local Build & Test Commands

### 1. Build the `bento7z` Engine

Must be run before building `BentoZip.xcodeproj` (the Xcode build phase copies and codesigns `engine/bento7z/build/bento7z` and `engine/bento7z/build/7z.so` into `BentoZip.app/Contents/Helpers/`):

```bash
./scripts/build-engine.sh
```

### 2. Build & Test the macOS App

```bash
# Build BentoZipCore Swift package independently
cd BentoZipCore && swift build -Xswiftc -warnings-as-errors

# Build the macOS app (Debug)
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug build

# Run unit tests
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug -only-testing:BentoZipTests test
```

### 3. Website (`website/`)

```bash
pnpm --dir website install
pnpm --dir website dev
pnpm --dir website build
```

## Release & Signing Workflow

CI and Release automation live under `.github/workflows/`:

- **CI (`.github/workflows/ci.yml`)**: Runs on pushes to `main` and pull requests. Builds `engine/bento7z`, checks for prohibited middle-dot (`U+00B7`) characters in `BentoZip/` and `BentoZipCore/`, builds `BentoZipCore` with `-warnings-as-errors`, builds the Xcode Debug target, runs `BentoZipTests`, and builds `website/`.
- **Release (`.github/workflows/release.yml`)**: Triggered by `v*` tags (verified against `MARKETING_VERSION` in `BentoZip.xcodeproj/project.pbxproj`) or `workflow_dispatch`. Executes `./scripts/build-release.sh`, signs `7z.so`, `bento7z`, `BentoZip.app`, and the UDZO `.dmg` (created via `./scripts/create-dmg.sh`), notarizes and staples both the app and DMG when signing secrets are configured, generates `SHA256SUMS.txt`, and publishes the GitHub Release.

To enable Developer ID signing and Apple notarization in GitHub Actions, configure the following repository secrets (secret names only; no values are stored in this repository):

- `MACOS_CERT_P12`
- `MACOS_CERT_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `MACOS_DEVELOPER_ID`
- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
