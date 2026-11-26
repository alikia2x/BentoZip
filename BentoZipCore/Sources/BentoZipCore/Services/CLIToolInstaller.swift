import Foundation

/// Errors thrown while installing or uninstalling the `bentozip` command-line wrapper.
public enum CLIToolInstallerError: LocalizedError, Sendable, Equatable {
    case permissionDenied(String)
    case installFailed(String)
    case uninstallFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let path):
            return String(localized: "Write permission denied for \(path).", bundle: .module)
        case .installFailed(let detail):
            return String(localized: "Failed to install CLI tool: \(detail)", bundle: .module)
        case .uninstallFailed(let detail):
            return String(localized: "Failed to uninstall CLI tool: \(detail)", bundle: .module)
        case .cancelled:
            return String(localized: "Operation was cancelled.", bundle: .module)
        }
    }
}

/// Installs and manages the `bentozip` POSIX shell CLI wrapper (default `/usr/local/bin/bentozip`).
public struct CLIToolInstaller: Sendable {
    public static let defaultInstallPath = "/usr/local/bin/bentozip"
    private static let wrapperMarker = "# BentoZip CLI wrapper"

    public let installURL: URL
    public let appBundleURL: URL

    public init(
        installPath: String = CLIToolInstaller.defaultInstallPath,
        appBundleURL: URL = Bundle.main.bundleURL
    ) {
        self.installURL = URL(fileURLWithPath: installPath)
        self.appBundleURL = appBundleURL
    }

    /// Return `true` when an executable BentoZip wrapper script is installed at `installURL`.
    public var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: installURL.path),
              let content = try? String(contentsOf: installURL, encoding: .utf8) else {
            return false
        }
        return content.contains(Self.wrapperMarker)
    }

    /// Generate a POSIX `/bin/sh` wrapper script invoking `BentoZip.app` and its bundled `bento7z` helper.
    public static func generateWrapperScript(appBundlePath: String) -> String {
        let escapedApp = shellSingleQuoted(appBundlePath)
        return """
        #!/bin/sh
        \(wrapperMarker)
        set -eu

        APP_BUNDLE=\(escapedApp)
        BENTO7Z="$APP_BUNDLE/Contents/Helpers/bento7z"
        BENTO7Z_LIB="$APP_BUNDLE/Contents/Helpers/7z.so"

        print_help() {
            cat <<'EOF'
        Usage: bentozip <command> [options] [arguments]

        Commands:
          open <path...>                      Open archive(s) or folder(s) in BentoZip.app
          list <archive> [--password <pw>]    List entries inside an archive
          extract <archive> [dest] [--password <pw>]
                                              Extract an archive to destination directory
          compress <output> <input...> [--format <fmt>] [--level <lvl>] [--password <pw>]
                                              Create an archive from one or more inputs
          test <archive> [--password <pw>]    Verify archive integrity
          -h, --help                          Show this help message
        EOF
        }

        require_helper() {
            if [ ! -x "$BENTO7Z" ]; then
                echo "bentozip: bundled helper not found at $BENTO7Z" >&2
                exit 1
            fi
        }

        run_jsonl() {
            require_helper
            BENTO7Z_LIBRARY="$BENTO7Z_LIB" "$BENTO7Z"
        }

        if [ $# -eq 0 ]; then
            open -a "$APP_BUNDLE"
            exit 0
        fi

        CMD="$1"
        case "$CMD" in
            -h|--help|help)
                print_help
                exit 0
                ;;
            open)
                shift
                if [ $# -eq 0 ]; then
                    open -a "$APP_BUNDLE"
                else
                    open -a "$APP_BUNDLE" "$@"
                fi
                exit 0
                ;;
            list|test)
                shift
                if [ $# -lt 1 ]; then
                    echo "bentozip: missing archive path" >&2
                    exit 2
                fi
                ARCHIVE="$1"
                shift
                PASSWORD=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -p|--password)
                            PASSWORD="${2:-}"
                            shift 2
                            ;;
                        *)
                            echo "bentozip: unknown option '$1'" >&2
                            exit 2
                            ;;
                    esac
                done
                /usr/bin/python3 - "$CMD" "$ARCHIVE" "$PASSWORD" <<'PY' | run_jsonl
        import json, os, sys
        cmd, archive, password = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
        params = {"archive": archive}
        if password:
            params["password"] = password
        print(json.dumps({"id": "cli", "command": cmd, "params": params}))
        PY
                exit $?
                ;;
            extract)
                shift
                if [ $# -lt 1 ]; then
                    echo "bentozip: missing archive path" >&2
                    exit 2
                fi
                ARCHIVE="$1"
                shift
                DEST="."
                PASSWORD=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -p|--password)
                            PASSWORD="${2:-}"
                            shift 2
                            ;;
                        *)
                            DEST="$1"
                            shift
                            ;;
                    esac
                done
                /usr/bin/python3 - "$ARCHIVE" "$DEST" "$PASSWORD" <<'PY' | run_jsonl
        import json, os, sys
        archive, dest, password = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2]), sys.argv[3]
        params = {"archive": archive, "output": dest}
        if password:
            params["password"] = password
        print(json.dumps({"id": "cli", "command": "extract", "params": params}))
        PY
                exit $?
                ;;
            compress)
                shift
                if [ $# -lt 2 ]; then
                    echo "bentozip: usage: bentozip compress <output> <input...>" >&2
                    exit 2
                fi
                OUTPUT="$1"
                shift
                FORMAT=""
                LEVEL="normal"
                PASSWORD=""
                INPUTS=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -f|--format)
                            FORMAT="${2:-}"
                            shift 2
                            ;;
                        -l|--level)
                            LEVEL="${2:-normal}"
                            shift 2
                            ;;
                        -p|--password)
                            PASSWORD="${2:-}"
                            shift 2
                            ;;
                        *)
                            break
                            ;;
                    esac
                done
                if [ $# -lt 1 ]; then
                    echo "bentozip: missing input paths" >&2
                    exit 2
                fi
                /usr/bin/python3 - "$OUTPUT" "$FORMAT" "$LEVEL" "$PASSWORD" "$@" <<'PY' | run_jsonl
        import json, os, sys
        output = os.path.abspath(sys.argv[1])
        fmt = sys.argv[2]
        level = sys.argv[3]
        password = sys.argv[4]
        paths = [os.path.abspath(p) for p in sys.argv[5:]]
        params = {"archive": output, "paths": paths, "level": level, "preserve_paths": True}
        if fmt:
            params["format"] = fmt
        if password:
            params["password"] = password
        print(json.dumps({"id": "cli", "command": "compress", "params": params}))
        PY
                exit $?
                ;;
            *)
                open -a "$APP_BUNDLE" "$@"
                exit 0
                ;;
        esac
        """
    }

    /// Install the `bentozip` CLI wrapper script to `installURL`.
    public func install(allowAdminPrompt: Bool = true) async throws {
        try Task.checkCancellation()
        let script = Self.generateWrapperScript(appBundlePath: appBundleURL.path)
        let targetURL = installURL
        let parentURL = targetURL.deletingLastPathComponent()

        let canWriteDirectly = await Task.detached(priority: .userInitiated) {
            Self.canWriteDirectly(toDirectory: parentURL)
        }.value

        if canWriteDirectly {
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                if !fm.fileExists(atPath: parentURL.path) {
                    try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
                }
                try script.write(to: targetURL, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
            }.value
            return
        }

        guard allowAdminPrompt else {
            throw CLIToolInstallerError.permissionDenied(targetURL.path)
        }

        let tempScriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bentozip_cli_\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: tempScriptURL) }

        try await Task.detached(priority: .userInitiated) {
            try script.write(to: tempScriptURL, atomically: true, encoding: .utf8)
        }.value

        let shellCommand = "mkdir -p \(Self.shellSingleQuoted(parentURL.path)) && cp \(Self.shellSingleQuoted(tempScriptURL.path)) \(Self.shellSingleQuoted(targetURL.path)) && chmod 755 \(Self.shellSingleQuoted(targetURL.path))"
        try await runPrivilegedShellScript(shellCommand, isUninstall: false)
    }

    /// Uninstall the `bentozip` CLI wrapper from `installURL`.
    public func uninstall(allowAdminPrompt: Bool = true) async throws {
        try Task.checkCancellation()
        let targetURL = installURL
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }

        let parentURL = targetURL.deletingLastPathComponent()
        let canWriteDirectly = await Task.detached(priority: .userInitiated) {
            Self.canWriteDirectly(toDirectory: parentURL)
        }.value

        if canWriteDirectly {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: targetURL)
            }.value
            return
        }

        guard allowAdminPrompt else {
            throw CLIToolInstallerError.permissionDenied(targetURL.path)
        }

        let shellCommand = "rm -f \(Self.shellSingleQuoted(targetURL.path))"
        try await runPrivilegedShellScript(shellCommand, isUninstall: true)
    }

    // MARK: - Helpers

    private static func canWriteDirectly(toDirectory directoryURL: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: directoryURL.path) {
            return fm.isWritableFile(atPath: directoryURL.path)
        }
        var ancestor = directoryURL.deletingLastPathComponent()
        while ancestor.path != "/" && !fm.fileExists(atPath: ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
        }
        return fm.isWritableFile(atPath: ancestor.path)
    }

    private func runPrivilegedShellScript(_ shellCommand: String, isUninstall: Bool) async throws {
        let escapedForAppleScript = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

        do {
            try await DiskImageEngine.runSubprocess(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", appleScript]
            )
        } catch is CancellationError {
            throw CLIToolInstallerError.cancelled
        } catch let error as Bento7zError {
            let desc = error.localizedDescription
            if desc.contains("-128") || desc.localizedCaseInsensitiveContains("User canceled") {
                throw CLIToolInstallerError.cancelled
            }
            throw isUninstall ? CLIToolInstallerError.uninstallFailed(desc) : CLIToolInstallerError.installFailed(desc)
        } catch {
            throw isUninstall
                ? CLIToolInstallerError.uninstallFailed(error.localizedDescription)
                : CLIToolInstallerError.installFailed(error.localizedDescription)
        }
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
