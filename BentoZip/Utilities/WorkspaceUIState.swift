import BentoZipCore
import Observation
import SwiftUI

/// Per-window ephemeral UI state for sheets and toolbar search focus requests.
@Observable
@MainActor
final class WorkspaceUIState {
    var showNewFolderSheet: Bool = false
    var renameTargetEntry: FileEntry?
    var searchFocusRequestID: UInt64 = 0
    var outlineFocusRequestID: UInt64 = 0

    func requestSearchFocus() {
        searchFocusRequestID &+= 1
    }

    func requestOutlineFocus() {
        outlineFocusRequestID &+= 1
    }
}

private struct ActiveAppStateFocusedKey: FocusedValueKey {
    typealias Value = AppState
}

private struct ActiveProgressStateFocusedKey: FocusedValueKey {
    typealias Value = ProgressState
}

private struct ActiveWorkspaceUIStateFocusedKey: FocusedValueKey {
    typealias Value = WorkspaceUIState
}

extension FocusedValues {
    var activeAppState: AppState? {
        get { self[ActiveAppStateFocusedKey.self] }
        set { self[ActiveAppStateFocusedKey.self] = newValue }
    }

    var activeProgressState: ProgressState? {
        get { self[ActiveProgressStateFocusedKey.self] }
        set { self[ActiveProgressStateFocusedKey.self] = newValue }
    }

    var activeWorkspaceUIState: WorkspaceUIState? {
        get { self[ActiveWorkspaceUIStateFocusedKey.self] }
        set { self[ActiveWorkspaceUIStateFocusedKey.self] = newValue }
    }
}
