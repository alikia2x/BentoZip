# bento7z

A JSONL-based CLI wrapper around [bit7z](https://github.com/rikyoz/bit7z). It reads JSON Lines requests from stdin and writes JSON Lines responses to stdout, making it suitable for integration with other programs (e.g., AI agents, shell pipelines, web services) that need to create, inspect, or extract archives.

## Requirements

- C++17 compiler (GCC 8+, Clang 10+, Apple Clang 14+, MSVC 2019+)
- CMake 3.20+
- make (or Ninja)
- 7-Zip source (automatically downloaded by the build system)

### macOS

Install p7zip (optional, provides a system `7z.so` fallback):

```
brew install p7zip
```

On Apple Silicon, the build system also looks for `7z.so` at `/opt/homebrew/lib/p7zip/` and `/usr/local/lib/p7zip/`.

### Linux

Install p7zip development headers or the full package (optional):

```
sudo apt install p7zip p7zip-full    # Debian/Ubuntu
sudo dnf install p7zip p7zip-devel   # Fedora
```

The build system looks for `7z.so` at `/usr/lib/7z.so` and `/usr/lib/p7zip/7z.so`.

### Windows

The build system looks for `7z.dll` and `7za.dll` next to the executable or in the system PATH.

## Build

```sh
git clone <repo-url> bento7z
cd bento7z

cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

The build produces a single binary at `build/bento7z` and a bundled `build/7z.so` (on Unix) compiled from the 7-Zip source.

The built binary's rpath is set to the build directory, so the bundled `7z.so` is discovered automatically at runtime. When the binary is installed elsewhere, set `BENTO7Z_LIBRARY` or place `7z.so` next to the binary.

## Protocol

bento7z uses JSON Lines (JSONL). Each line on stdin is a single JSON request object. Each request produces one or more JSON response lines on stdout.

### Request Format

```json
{
    "id": "string (required, echoed in responses)",
    "command": "string (required, one of: list, compress, extract)",
    "params": { }
}
```

### Response Types

All responses are JSON objects written one per line to stdout.

**result**: The command succeeded.

```json
{"id": "...", "type": "result", "data": { ... }}
```

**progress**: A progress update during a compress or extract operation. Throttled to at most once per 100 ms.

```json
{"id": "...", "type": "progress", "data": {"processed_bytes": 1024, "total_bytes": 99999, "current_file": "..."}}
```

**file**: A file is about to be processed (emitted during compress/extract before each entry).

```json
{"id": "...", "type": "file", "data": {"path": "relative/path/inside/archive"}}
```

**error**: The command failed.

```json
{"id": "...", "type": "error", "data": {"message": "...", "code": "..."}}
```

Progress and file responses are interleaved before the final result or error response. The client should read responses line by line and match them by `id`.

## Commands

### list

Inspect the contents of an existing archive.

Parameters:

| Field      | Type   | Required | Description                                                                 |
|------------|--------|----------|-----------------------------------------------------------------------------|
| `archive`  | string | yes      | Path to the archive file                                                    |
| `password` | string | no       | Archive password, if encrypted                                              |
| `format`   | string | no       | Explicit format override (default: `"auto"` for extension/magic detection)  |

When `format` is omitted or `"auto"`, the archive format is auto-detected from extension and magic bytes. Compound tar archives (`.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tbz`, `.tar.xz`, `.txz`), as well as single-stream `.gz`, `.bz2`, and `.xz` files whose inner stream is a `.tar` archive, are automatically unwrapped to inspect their inner tar entries. Pass `"format": "gz"` / `"gzip"` (or `"bz2"` / `"bzip2"`, `"xz"`) on a compound tar extension (e.g. `.tar.gz`) to inspect only the outer compressed wrapper.

Result data:

```json
{
    "archive": "/path/to/archive.7z",
    "items_count": 42,
    "files_count": 40,
    "folders_count": 2,
    "size": 1048576,
    "packed_size": 524288,
    "items": [
        {
            "index": 0,
            "name": "foo.txt",
            "path": "foo.txt",
            "extension": "txt",
            "is_dir": false,
            "size": 1024,
            "packed_size": 512,
            "crc": 123456789,
            "encrypted": false,
            "modified_at": 1700000000
        }
    ]
}
```

`modified_at` is a Unix timestamp in seconds (`int64`), and is omitted when the archive item has no modification timestamp.

### compress

Create a new archive from files and directories.

Parameters:

| Field            | Type     | Required | Description                                                        |
|------------------|----------|----------|--------------------------------------------------------------------|
| `archive`        | string   | yes      | Output archive path                                                |
| `paths`          | string[] | yes      | Files and directories to add                                       |
| `format`         | string   | no       | Archive format (default: `"7z"`; `"auto"` infers from extension)    |
| `level`          | string   | no       | Compression level (default: `"normal"`)                            |
| `password`       | string   | no       | Encrypt the archive with this password                             |
| `preserve_paths` | bool     | no       | Preserve directory hierarchy (default: `true`; `false` flattens)   |
| `exclude`        | string[] | no       | Glob/name/path patterns to exclude (e.g., `".DS_Store"`, `"*.tmp"`) |

Supported formats: `7z`, `zip`, `tar`, `gz` / `gzip`, `bz2` / `bzip2`, `xz`, `wim`, `tar.gz` / `tgz`, `tar.bz2` / `tbz2` / `tbz`, `tar.xz` / `txz` (plus `"auto"` to infer from `archive`).

`paths` must be non-empty; empty `paths` is rejected with `INVALID_PARAMS`.

`password` is supported only for `7z` and `zip`. Passing a non-empty `password` for any other format returns `INVALID_PARAMS`. For `7z` archives with a `password`, header encryption is enabled automatically.

Compression levels (from fastest to best ratio): `none`, `fastest`, `fast`, `normal`, `max`, `ultra`.

The number of worker threads is set to the number of available hardware threads.

Result data:

```json
{
    "archive": "/path/to/output.7z",
    "paths_count": 5
}
```

### extract

Extract an archive to a directory.

Parameters:

| Field      | Type     | Required | Description                                                                |
|------------|----------|----------|----------------------------------------------------------------------------|
| `archive`  | string   | yes      | Path to the archive file                                                   |
| `output`   | string   | yes      | Output directory                                                           |
| `password` | string   | no       | Archive password, if encrypted                                             |
| `format`   | string   | no       | Explicit format override (default: `"auto"` for extension/magic detection) |
| `entries`  | string[] | no       | Specific file or folder paths within the archive to extract (default: all) |

The output directory is created if it does not exist. Before extracting any item (for both full and selective extraction), all archive item paths and symlink targets are validated to ensure they remain safely inside `output`. Any archive containing an absolute path, Windows drive prefix, `..` traversal component, or escaping symlink target is rejected with `PATH_TRAVERSAL` without writing unsafe files.

Format auto-detection and compound tar unwrapping work the same way as `list`.

When `entries` is provided and non-empty, only items matching an exact normalized path or a directory prefix (`entry + "/"`) are extracted. If none of the requested entries match, an error with code `PATH_NOT_FOUND` is returned.

Result data:

```json
{
    "archive": "/path/to/archive.7z",
    "output_dir": "/path/to/output"
}
```

## Error Codes

| Code                | Description                                                   |
|---------------------|---------------------------------------------------------------|
| `UNKNOWN_COMMAND`   | Request contains an unrecognized command name                 |
| `INVALID_PARAMS`    | Request JSON or parameters failed validation/type conversion  |
| `PATH_NOT_FOUND`    | Input path does not exist or no requested `entries` matched   |
| `PATH_TRAVERSAL`    | Archive item path or symlink target escapes output directory  |
| `PASSWORD_REQUIRED` | Archive requires a password and none was provided             |
| `WRONG_PASSWORD`    | Provided archive password is incorrect                        |
| `BIT7Z_ERROR`       | Other error from the bit7z library (corrupt archive, I/O, etc.) |
| `INTERNAL_ERROR`    | Unexpected internal error                                     |

Error messages contain a human-readable explanation from the library or the runtime.

## Environment Variables

| Variable          | Description                                                        |
|-------------------|--------------------------------------------------------------------|
| `BENTO7Z_LIBRARY` | Path to the 7-Zip shared library (overrides auto-detection)        |
| `BENTO7Z_DEBUG`   | Set to a non-empty value (other than `"0"`) for stderr diagnostics |

The library search order is:
1. `BENTO7Z_LIBRARY` environment variable
2. `7z.so` / `7z.dll` next to the bento7z executable
3. System-specific fallback paths (e.g., `/opt/homebrew/lib/p7zip/7z.so` on macOS ARM, `/usr/lib/p7zip/7z.so` on Linux)
4. Default name `7z.so` or `7z.dll` (system library search)
