import AppKit
import BentoZipCore
import SwiftUI

@MainActor
final class UpdateCheckWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateCheckWindowController()

    private var window: NSWindow?
    private var checkTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func showAndCheck(using checker: UpdateChecker) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let rootView = UpdateCheckSheet(updateChecker: checker) { [weak self] in
                self?.close()
            }
            let hosting = NSHostingController(rootView: rootView)
            let created = NSWindow(contentViewController: hosting)
            created.title = String(localized: "Software Update")
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 420, height: 240))
            created.center()
            created.delegate = self
            created.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = created
        }

        checkTask?.cancel()
        checkTask = Task { @MainActor in
            await checker.checkForUpdates()
        }
    }

    func close() {
        checkTask?.cancel()
        checkTask = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        checkTask?.cancel()
        checkTask = nil
    }
}

struct UpdateCheckSheet: View {
    let updateChecker: UpdateChecker
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch updateChecker.status {
            case .idle, .checking:
                checkingView

            case .upToDate(let currentVersion):
                upToDateView(currentVersion: currentVersion)

            case .updateAvailable(let release):
                updateAvailableView(release: release)

            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Checking for Updates…")
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(localized: "Current version: \(updateChecker.currentVersion)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView()
                .progressViewStyle(.linear)

            HStack {
                Spacer()
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func upToDateView(currentVersion: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text("BentoZip is Up to Date")
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(localized: "Version \(currentVersion) is currently the newest version available."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("Check Again") {
                    Task {
                        await updateChecker.checkForUpdates()
                    }
                }
                Spacer()
                Button("OK") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func updateAvailableView(release: GitHubReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("A New Version is Available")
                        .font(.system(size: 14, weight: .semibold))
                    Text(release.name.isEmpty ? release.tagName : release.name)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(String(localized: "Installed: \(updateChecker.currentVersion), Latest: \(release.tagName)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            if !release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(release.body)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 130)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.75)
                )
            }

            HStack(spacing: 8) {
                Button("Release Notes") {
                    NSWorkspace.shared.open(release.htmlURL)
                }

                Spacer()

                Button("Later") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Download Release") {
                    NSWorkspace.shared.open(release.downloadURL ?? release.htmlURL)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Update Check Failed")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Try Again") {
                    Task {
                        await updateChecker.checkForUpdates()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
