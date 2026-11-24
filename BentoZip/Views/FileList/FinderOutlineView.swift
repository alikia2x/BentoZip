import AppKit
import BentoZipCore
import QuickLookUI

@MainActor
final class FinderOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?
    var onOpen: (() -> Void)?
    var onNavigateUp: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    var onContextMenu: (([FileNode]) -> NSMenu?)?
    var onMovedToWindow: (() -> Void)?
    var onBecameQuickLookOwner: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onMovedToWindow?()
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        switch event.keyCode {
        case 49 where modifiers.isEmpty: // Space
            onSpace?()
        case 36 where modifiers.isEmpty,
             76 where modifiers.isEmpty: // Return / Numpad Enter
            onOpen?()
        case 125 where modifiers == .command: // Cmd+Down
            onOpen?()
        case 126 where modifiers == .command: // Cmd+Up
            onNavigateUp?()
        case 51 where modifiers.isEmpty || modifiers == .command,
             117 where modifiers.isEmpty || modifiers == .command: // Delete / Forward Delete
            onDelete?()
        case 53 where modifiers.isEmpty: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Context Menu (Finder Row Targeting)

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }

        let targetNodes: [FileNode]
        if selectedRowIndexes.contains(clickedRow) {
            targetNodes = selectedRowIndexes.compactMap { item(atRow: $0) as? FileNode }
        } else if let clickedNode = item(atRow: clickedRow) as? FileNode {
            targetNodes = [clickedNode]
        } else {
            return nil
        }

        guard !targetNodes.isEmpty else { return nil }
        return onContextMenu?(targetNodes)
    }

    // MARK: - QLPreviewPanelController

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookHelper.shared.beginControl(panel: panel, owner: self)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookHelper.shared.endControl(panel: panel, owner: self)
    }
}
