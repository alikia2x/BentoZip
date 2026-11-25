import AppKit
import BentoZipCore
import Observation
import SwiftUI

/// Owns the single standalone macOS Progress / Transfers window (similar to Finder's Copy window).
/// Automatically opens when any window starts an archive task, stacks concurrent tasks vertically,
/// and closes deterministically when all tasks finish.
@MainActor
final class TransferWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TransferWindowController()

    private let transferManager: TransferManager
    private var isObserving = false
    private var hasPositionedOnce = false

    private init(transferManager: TransferManager = .shared) {
        self.transferManager = transferManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 84),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Progress")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("BentoZipTransferWindow")

        let hostingView = NSHostingView(rootView: TransferWindowView(transferManager: transferManager))
        hostingView.sizingOptions = [.intrinsicContentSize]
        window.contentView = hostingView

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        observeTransferTasks()
    }

    func showProgressWindow(makeKey: Bool = false) {
        guard let window else { return }
        if !hasPositionedOnce && !window.isVisible {
            positionNearActiveWindow(window)
            hasPositionedOnce = true
        }
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func observeTransferTasks() {
        let hasTasks = withObservationTracking {
            transferManager.hasActiveTasks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeTransferTasks()
            }
        }

        if hasTasks {
            showProgressWindow(makeKey: false)
        } else if let window, window.isVisible {
            window.orderOut(nil)
        }
    }

    private func positionNearActiveWindow(_ progressWindow: NSWindow) {
        if let anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow,
           anchor !== progressWindow {
            let anchorFrame = anchor.frame
            let size = progressWindow.frame.size
            let x = anchorFrame.maxX - size.width - 24
            let y = anchorFrame.maxY - size.height - 52
            if let screenFrame = (anchor.screen ?? NSScreen.main)?.visibleFrame {
                let clampedX = min(max(x, screenFrame.minX + 16), screenFrame.maxX - size.width - 16)
                let clampedY = min(max(y, screenFrame.minY + 16), screenFrame.maxY - size.height - 16)
                progressWindow.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
                return
            }
        }
        progressWindow.center()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if transferManager.hasActiveTasks {
            transferManager.cancelAll()
        }
        return true
    }
}
