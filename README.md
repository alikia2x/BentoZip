# BentoZip

**Browse, preview, edit, and pack archives on macOS like a native Finder window.**

BentoZip is a fast, local-first archive manager built for macOS 14+. Open an archive to inspect its folder tree without extracting everything first, drag out individual files on demand, edit existing archives in place, and integrate archive workflows directly into Finder, Quick Look, Spotlight, Shortcuts, and your terminal—with everything processed locally on your Mac and zero telemetry.

## Why BentoZip

- **Finder-style browsing & instant preview**: Switch between list and Grid (`⌘2`) views with breadcrumb navigation, live search, Spacebar Quick Look, inline text and image previews, lazy drag-out extraction, and a dedicated Image Gallery for `CBZ`, `CBR`, and image folders.
- **Broad format creation**: Create `ZIP` (AES-256 or ZipCrypto), `7z` (with optional header encryption), `TAR`, `TAR.GZ`, `TAR.BZ2`, `TAR.XZ`, Apple Archive (`AAR`), HFS+ `DMG`, `Zstd` / `TAR.ZST` (via `zstd`), and multi-volume split archives.
- **Wide read & extraction support**: Open and extract `RAR`, `ISO`, `XAR` / `PKG`, `CAB`, `WIM`, `CPIO`, `LZMA`, `DEB`, `RPM`, `LZH`, `SquashFS`, `VMDK`, `CHM`, `ARJ`, `EPUB`, `LZ4` / `TAR.LZ4`, `Brotli`, and split volumes, with automatic CJK filename encoding recovery for legacy `ZIP` archives.
- **In-place editing & verification**: Rename, move, add, delete, or change passwords directly inside `ZIP`, `7z`, and `TAR` archives, drill into nested archives, save changes back automatically after editing files in external apps, verify archive integrity, and compute `SHA-256` / `MD5` checksums.
- **Workflow & security tools**: Save reusable Compression Presets, compress multiple items into separate archives or extract multiple archives at once, and store archive passwords in the macOS Keychain Password Vault with Touch ID unlock and a built-in strong password generator.
- **Deep macOS integration**: Works across the macOS Services menu, Quick Look extension, Finder Sync context menu, Spotlight archive indexing, Apple Shortcuts, a `bentozip` CLI wrapper, and an in-app GitHub Releases updater.

## Download & Install

Grab the latest Universal macOS (`arm64` + `x86_64`, macOS 14+) build from [GitHub Releases](https://github.com/alikia2x/BentoZip/releases/latest):

1. Download `BentoZip-<version>-macos-universal.dmg` (or `.zip`).
2. Open the disk image and drag **BentoZip** into **Applications**.
3. Optionally install the `bentozip` command-line wrapper from **BentoZip > Settings** (installs to `/usr/local/bin/bentozip`).

## Developer Quickstart

### Prerequisites

- macOS 14.0+ and Xcode 15.0+
- CMake 3.20+ and Apple Clang (for the bundled `bento7z` engine)
- Optional CLI compressors on `PATH`: `zstd`, `lz4`, and `brotli` (for `Zstd`, `LZ4`, and `Brotli` archive support)
- Optional for `website/`: Node.js 22+ and pnpm 10+

### Build the Engine & App

Build the bundled `bento7z` engine first (Xcode copies and signs `bento7z` and `7z.so` into the app bundle):

```bash
./scripts/build-engine.sh
# Or build a universal arm64 + x86_64 engine binary:
./scripts/build-engine.sh --universal
```

Build the core Swift package, build the macOS app, and run unit tests:

```bash
cd BentoZipCore && swift build -Xswiftc -warnings-as-errors
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug build
xcodebuild -project BentoZip.xcodeproj -scheme BentoZip -configuration Debug -only-testing:BentoZipTests test
```

### Website (`website/`)

```bash
pnpm --dir website install
pnpm --dir website dev
pnpm --dir website build
```

### Release Workflow

Bump the Xcode marketing/build version and fold `CHANGELOG.md` `[Unreleased]` notes into a release entry:

```bash
./scripts/release.sh <major|minor|patch|x.y.z> [--dry-run] [--skip-changelog]
```

Build universal release `.dmg` and `.zip` artifacts locally into `dist/` (with optional `CODESIGN=1` and `NOTARIZE=1`):

```bash
./scripts/build-release.sh --universal
```

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which verifies the version, tests, and website, builds universal artifacts, signs and notarizes when the secrets below are configured, generates `SHA256SUMS.txt`, and publishes the GitHub Release:

| Secret | Purpose |
|---|---|
| `MACOS_CERT_P12` | Base64-encoded Developer ID Application `.p12` certificate |
| `MACOS_CERT_PASSWORD` | Password for the `.p12` certificate |
| `MACOS_KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `MACOS_DEVELOPER_ID` | Signing identity name (`Developer ID Application: ...`) |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_ID` | Apple ID email for `notarytool` |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for Apple notarization |

## License

No `LICENSE` file is currently present in this repository.
