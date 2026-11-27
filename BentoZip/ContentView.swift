import AppKit
import BentoZipCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

    @AppStorage("BentoZipInspectorWidth") private var storedInspectorWidth: Double = 272
    @State private var keepInspectorMounted = false
    @State private var animatedInspectorProgress: CGFloat = 0
    @State private var showErrorAlert = false
    @State private var showToolbarDeleteConfirmation = false
    @State private var isTargeted = false

    private static let minInspectorWidth: CGFloat = 240
    private static let idealInspectorWidth: CGFloat = 272
    private static let maxInspectorWidth: CGFloat = 400

    private var canAcceptFileDrop: Bool {
        appState.mode == .compress || appState.isWritableArchive
    }

    private var windowTitle: String {
        switch appState.mode {
        case .empty:
            return ""
        case .compress:
            return appState.compressionSettings.archiveName.isEmpty
                ? appState.suggestedArchiveName
                : appState.compressionSettings.archiveName
        case .browseArchive:
            return appState.sourceArchiveURL?.lastPathComponent ?? ""
        }
    }

    private var windowSubtitle: String {
        switch appState.mode {
        case .empty:
            return ""
        case .compress:
            return String(localized: "\(appState.rootNodes.count) items")
        case .browseArchive:
            if let format = appState.archiveFormatName {
                return appState.isReadOnlyArchive
                    ? String(localized: "\(format) (Read-Only)")
                    : format
            }
            return ""
        }
    }

    var body: some View {
        @Bindable var appState = appState
        @Bindable var uiState = uiState

        Group {
            switch appState.mode {
            case .empty:
                EmptyStateView()
            case .compress, .browseArchive:
                workspaceView(showInspector: $appState.showInspector)
            }
        }
        .onChange(of: appState.isSearchVisible) { _, visible in
            if !visible && !appState.searchQuery.isEmpty {
                appState.searchQuery = ""
            }
        }
        .background(
            WindowDocumentBridge(
                appState: appState,
                progressState: progressState,
                uiState: uiState,
                mode: appState.mode,
                sourceArchiveURL: appState.sourceArchiveURL
            )
            .frame(width: 0, height: 0)
        )
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbarBackground(appState.mode == .empty ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            ToolbarCommands(
                showDeleteConfirmation: $showToolbarDeleteConfirmation,
                selectedCount: appState.selectedNodes.count,
                isLoading: appState.isLoading,
                isOperationInProgress: progressState.isOperationInProgress,
                hasRootItems: !appState.rootNodes.isEmpty
            )
        }
        .onOpenURL { url in
            DocumentWindowRouter.shared.openExternalURLs([url])
        }
        .onChange(of: appState.lastError) { _, newValue in
            showErrorAlert = newValue != nil
        }
        .sheet(isPresented: $appState.needsPasswordPrompt) {
            PasswordPromptSheet { password in
                await appState.coordinator.submitPassword(
                    password,
                    appState: appState,
                    progressState: progressState
                )
            }
            .environment(appState)
            .interactiveDismissDisabled(appState.isLoading)
        }
        .sheet(item: $appState.activeConflictPrompt, onDismiss: {
            appState.activeConflictPrompt?.cancel()
            appState.activeConflictPrompt = nil
        }) { prompt in
            ConflictResolutionSheet(prompt: prompt)
        }
        .sheet(item: $uiState.renameTargetEntry) { entry in
            RenameEntrySheet(entry: entry) { newName in
                Task {
                    await appState.coordinator.renameEntry(
                        appState: appState,
                        entry: entry,
                        newName: newName,
                        progressState: progressState
                    )
                }
            }
        }
        .sheet(isPresented: $uiState.showNewFolderSheet) {
            NewFolderSheet(currentSubfolderPath: appState.currentSubfolderPath) { name in
                Task {
                    await appState.coordinator.createFolder(
                        appState: appState,
                        name: name,
                        progressState: progressState
                    )
                }
            }
        }
        .sheet(isPresented: $uiState.showUpdatePasswordSheet) {
            UpdatePasswordSheet()
        }
        .alert(
            testArchiveAlertTitle,
            isPresented: Binding(
                get: { appState.testArchiveResult != nil },
                set: { if !$0 { appState.testArchiveResult = nil } }
            ),
            presenting: appState.testArchiveResult
        ) { _ in
            Button("OK") { appState.testArchiveResult = nil }
        } message: { result in
            if result.passed {
                Text("\"\(result.archiveName)\" passed integrity verification (\(result.itemsCount) items).")
            } else {
                Text(result.errorMessage ?? String(localized: "The archive failed integrity verification."))
            }
        }
        .alert("Operation Failed", isPresented: $showErrorAlert) {
            Button("OK") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
        .confirmationDialog(
            Text("Delete \(appState.selectedNodes.count) selected items from archive?"),
            isPresented: $showToolbarDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let entriesToDelete = appState.selectedNodes.map { $0.toFileEntry() }
                Task {
                    await appState.coordinator.removeEntries(
                        appState: appState,
                        entries: entriesToDelete,
                        progressState: progressState
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This modifies the archive and cannot be undone.")
        }
    }

    private var testArchiveAlertTitle: String {
        guard let result = appState.testArchiveResult else { return "" }
        return result.passed
            ? String(localized: "Archive Verified")
            : String(localized: "Archive Integrity Failed")
    }

    private var resolvedInspectorWidth: CGFloat {
        min(max(CGFloat(storedInspectorWidth), Self.minInspectorWidth), Self.maxInspectorWidth)
    }

    private func workspaceView(showInspector: Binding<Bool>) -> some View {
        GeometryReader { proxy in
            let containerWidth = proxy.size.width > 0 ? proxy.size.width : 960
            let maxAllowedInspector = max(Self.minInspectorWidth, min(Self.maxInspectorWidth, containerWidth - 360))
            let effectiveInspectorWidth = min(resolvedInspectorWidth, maxAllowedInspector)
            let maxTrailingForMinLeft = max(0, containerWidth - 280)
            let totalTrailingWidth = min(effectiveInspectorWidth + 1, maxTrailingForMinLeft)
            let clampedPanelWidth = max(0, totalTrailingWidth - 1)

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    FileListView()
                    BreadcrumbView()
                    StatusBarView()
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { items, _ in
                    guard !items.isEmpty, canAcceptFileDrop else { return false }
                    if appState.mode == .compress {
                        appState.addEntries(from: items)
                        return true
                    } else if appState.isWritableArchive {
                        let targetPrefix = appState.currentSubfolderPath
                        Task {
                            await appState.coordinator.addEntries(
                                appState: appState,
                                urls: items,
                                targetPrefix: targetPrefix,
                                progressState: progressState
                            )
                        }
                        return true
                    }
                    return false
                } isTargeted: { targeted in
                    isTargeted = targeted && canAcceptFileDrop
                }
                .overlay {
                    if isTargeted && canAcceptFileDrop {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                            )
                            .padding(6)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.14), value: isTargeted)

                if keepInspectorMounted && totalTrailingWidth > 0 {
                    HStack(spacing: 0) {
                        InspectorResizeDivider(
                            width: Binding(
                                get: { clampedPanelWidth },
                                set: { newWidth in
                                    let clamped = min(max(newWidth, Self.minInspectorWidth), maxAllowedInspector)
                                    storedInspectorWidth = Double(clamped)
                                }
                            ),
                            idealWidth: min(Self.idealInspectorWidth, maxAllowedInspector)
                        )
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .zIndex(1)

                        CompressionSettingsView()
                            .frame(width: clampedPanelWidth)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(width: totalTrailingWidth)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(InspectorBackdropView())
                    .frame(width: totalTrailingWidth * animatedInspectorProgress, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .allowsHitTesting(showInspector.wrappedValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            keepInspectorMounted = showInspector.wrappedValue
            animatedInspectorProgress = showInspector.wrappedValue ? 1 : 0
        }
        .onChange(of: showInspector.wrappedValue) { _, newValue in
            if newValue {
                keepInspectorMounted = true
                withAnimation(.easeOut(duration: 0.20)) {
                    animatedInspectorProgress = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.20)) {
                    animatedInspectorProgress = 0
                } completion: {
                    if !appState.showInspector {
                        keepInspectorMounted = false
                    }
                }
            }
        }
    }
}

private struct InspectorBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct InspectorResizeDivider: NSViewRepresentable {
    @Binding var width: CGFloat
    let idealWidth: CGFloat

    func makeNSView(context: Context) -> DividerView {
        DividerView()
    }

    func updateNSView(_ view: DividerView, context: Context) {
        view.width = $width
        view.idealWidth = idealWidth
    }

    final class DividerView: NSView {
        var width: Binding<CGFloat>?
        var idealWidth: CGFloat = 0
        private var dragStart: (mouseX: CGFloat, width: CGFloat)?
        private var cursorTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTrackingArea {
                removeTrackingArea(cursorTrackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds.insetBy(dx: -4, dy: 0),
                options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited, .enabledDuringMouseDrag],
                owner: self
            )
            addTrackingArea(area)
            cursorTrackingArea = area
            window?.invalidateCursorRects(for: self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.insetBy(dx: -4, dy: 0).contains(local) ? self : nil
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            if dragStart == nil {
                NSCursor.arrow.set()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }

        override func resetCursorRects() {
            addCursorRect(bounds.insetBy(dx: -4, dy: 0), cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            guard let width else { return }
            if event.clickCount == 2 {
                width.wrappedValue = idealWidth
                return
            }
            dragStart = (event.locationInWindow.x, width.wrappedValue)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            NSCursor.resizeLeftRight.set()
            width?.wrappedValue = dragStart.width + dragStart.mouseX - event.locationInWindow.x
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
        }
    }
}
