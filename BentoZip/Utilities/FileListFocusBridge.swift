import AppKit
import QuickLookUI
import SwiftUI

/// Bridges AppKit `NSOutlineView` first-responder management and Finder keyboard shortcuts
/// so `.compress` and `.browseArchive` modes share identical active selection, arrow navigation,
/// and Spacebar Quick Look behavior without interfering with inspector text fields.
struct FileListFocusBridge: NSViewRepresentable {
    let focusTrigger: Int
    let selectionTrigger: Int
    let onSpace: @MainActor () -> Void
    let onOpen: @MainActor () -> Void
    let onNavigateUp: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    let onEscape: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.updateHandlers(
            onSpace: onSpace,
            onOpen: onOpen,
            onNavigateUp: onNavigateUp,
            onDelete: onDelete,
            onEscape: onEscape
        )
        context.coordinator.installEventMonitor()
        context.coordinator.claimFocusSoon(force: true)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.updateHandlers(
            onSpace: onSpace,
            onOpen: onOpen,
            onNavigateUp: onNavigateUp,
            onDelete: onDelete,
            onEscape: onEscape
        )
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            context.coordinator.claimFocusSoon(force: true)
        } else if context.coordinator.lastSelectionTrigger != selectionTrigger {
            context.coordinator.lastSelectionTrigger = selectionTrigger
            context.coordinator.claimFocusSoon(force: true)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeEventMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var lastFocusTrigger: Int = -1
        var lastSelectionTrigger: Int = -1

        private var keyMonitor: Any?
        private var onSpace: (@MainActor () -> Void)?
        private var onOpen: (@MainActor () -> Void)?
        private var onNavigateUp: (@MainActor () -> Void)?
        private var onDelete: (@MainActor () -> Void)?
        private var onEscape: (@MainActor () -> Void)?

        func updateHandlers(
            onSpace: @escaping @MainActor () -> Void,
            onOpen: @escaping @MainActor () -> Void,
            onNavigateUp: @escaping @MainActor () -> Void,
            onDelete: @escaping @MainActor () -> Void,
            onEscape: @escaping @MainActor () -> Void
        ) {
            self.onSpace = onSpace
            self.onOpen = onOpen
            self.onNavigateUp = onNavigateUp
            self.onDelete = onDelete
            self.onEscape = onEscape
        }

        func installEventMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            }
        }

        func removeEventMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        func claimFocusSoon(force: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.focusTableIfAppropriate(force: force)
            }
        }

        private func focusTableIfAppropriate(force: Bool) {
            guard let hostView,
                  let window = hostView.window,
                  window.attachedSheet == nil,
                  let tableView = findTableView(near: hostView) else {
                return
            }
            if !force && (window.firstResponder is NSTextView) {
                return
            }
            if window.firstResponder !== tableView {
                window.makeFirstResponder(tableView)
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard let hostView, let window = hostView.window else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Allow Spacebar or Escape to dismiss Quick Look even while QLPreviewPanel is key.
            if QLPreviewPanel.sharedPreviewPanelExists(),
               let panel = QLPreviewPanel.shared(),
               panel.isVisible,
               event.window === panel || event.window === window {
                if event.keyCode == 49 && modifiers.isEmpty {
                    onSpace?()
                    claimFocusSoon(force: true)
                    return nil
                }
                if event.keyCode == 53 && modifiers.isEmpty {
                    onEscape?()
                    claimFocusSoon(force: true)
                    return nil
                }
            }

            guard event.window === window,
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView) else {
                return event
            }

            let tableView = findTableView(near: hostView)

            switch event.keyCode {
            case 49 where modifiers.isEmpty: // Space
                onSpace?()
                return nil
            case 36 where modifiers.isEmpty: // Return
                onOpen?()
                return nil
            case 125 where modifiers == .command: // Cmd+Down
                onOpen?()
                return nil
            case 126 where modifiers == .command: // Cmd+Up
                onNavigateUp?()
                return nil
            case 51 where modifiers.isEmpty || modifiers == .command: // Delete / Cmd+Delete
                onDelete?()
                return nil
            case 53 where modifiers.isEmpty: // Escape
                onEscape?()
                return nil
            case 123, 124, 125, 126 where modifiers.isEmpty || modifiers == .shift: // Arrow keys
                if let tableView, window.firstResponder !== tableView {
                    window.makeFirstResponder(tableView)
                }
                return event
            default:
                return event
            }
        }

        private func findTableView(near anchor: NSView) -> NSTableView? {
            var current: NSView? = anchor
            for _ in 0..<4 {
                guard let container = current?.superview else { break }
                if let found = firstOutlineView(in: container, skipping: anchor) {
                    return found
                }
                current = container
            }
            return nil
        }

        private func firstOutlineView(in root: NSView, skipping excluded: NSView) -> NSOutlineView? {
            if let outline = root as? NSOutlineView {
                return outline
            }
            for subview in root.subviews where subview !== excluded {
                if let found = firstOutlineView(in: subview, skipping: excluded) {
                    return found
                }
            }
            return nil
        }
    }
}
