import AppKit
import BentoZipCore
import SwiftUI

struct ToolbarCommands: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

    @Binding var showDeleteConfirmation: Bool
    let selectedCount: Int
    let isLoading: Bool
    let isOperationInProgress: Bool
    let hasRootItems: Bool

    private var isBusy: Bool { isLoading || isOperationInProgress }

    var body: some ToolbarContent {
        @Bindable var appState = appState

        if appState.mode != .empty {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    appState.navigateUp()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!appState.canNavigateUp)
                .help("Back")

                Button {
                    appState.coordinator.detachWindowProgress(progressState)
                    appState.reset()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Back to Home")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if appState.mode == .compress {
                    Button {
                        chooseAndAddFiles()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(isBusy)
                    .help("Add Files or Folders")

                    Button {
                        appState.removeSelectedEntries()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(selectedCount == 0 || isBusy)
                    .help("Remove Selected")

                    Button {
                        Task {
                            await appState.coordinator.compress(
                                appState: appState,
                                progressState: progressState
                            )
                        }
                    } label: {
                        Label("Compress", systemImage: "archivebox")
                    }
                    .disabled(!hasRootItems || isBusy)
                    .help("Create Archive")
                } else if appState.mode == .browseArchive {
                    if appState.isWritableArchive {
                        Button {
                            chooseAndAddFiles()
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .disabled(isBusy)
                        .help("Add to Archive")

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedCount == 0 || isBusy)
                        .help("Delete Selected from Archive")
                    }

                    Menu {
                        Button {
                            Task {
                                await appState.coordinator.extract(
                                    appState: appState,
                                    progressState: progressState,
                                    chooseDestination: false
                                )
                            }
                        } label: {
                            Label("Extract Here", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            Task {
                                await appState.coordinator.extract(
                                    appState: appState,
                                    progressState: progressState,
                                    chooseDestination: true
                                )
                            }
                        } label: {
                            Label("Extract To…", systemImage: "folder.badge.plus")
                        }

                        if !appState.selectedNodes.isEmpty {
                            Divider()
                            Button {
                                let entries = appState.selectedNodes.map { $0.toFileEntry() }
                                Task {
                                    await appState.coordinator.extract(
                                        appState: appState,
                                        progressState: progressState,
                                        entries: entries,
                                        chooseDestination: false
                                    )
                                }
                            } label: {
                                Label("Extract Selected Here", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                let entries = appState.selectedNodes.map { $0.toFileEntry() }
                                Task {
                                    await appState.coordinator.extract(
                                        appState: appState,
                                        progressState: progressState,
                                        entries: entries,
                                        chooseDestination: true
                                    )
                                }
                            } label: {
                                Label("Extract Selected…", systemImage: "checkmark.rectangle.stack")
                            }
                        }
                    } label: {
                        Label("Extract", systemImage: "square.and.arrow.down")
                    } primaryAction: {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                chooseDestination: false
                            )
                        }
                    }
                    .disabled(isBusy)
                    .help("Extract")
                }
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .automatic)
            }

            ToolbarItem(placement: .automatic) {
                CollapsibleToolbarSearchView(
                    text: $appState.searchQuery,
                    isPresented: $appState.isSearchVisible,
                    focusRequestID: uiState.searchFocusRequestID,
                    onCommitToResults: { uiState.requestOutlineFocus() }
                )
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .automatic)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        appState.showInspector.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .accessibilityIdentifier("toolbar.inspector.button")
                .help(appState.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        } else {
            // Keep an invisible placeholder item in `.empty` mode so macOS preserves the same
            // unified toolbar height and traffic-light coordinates as the workspace window.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .automatic) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func chooseAndAddFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let urls = panel.urls
            if appState.mode == .compress {
                appState.addEntries(from: urls)
            } else if appState.isWritableArchive {
                let targetPrefix = appState.currentSubfolderPath
                Task {
                    await appState.coordinator.addEntries(
                        appState: appState,
                        urls: urls,
                        targetPrefix: targetPrefix,
                        progressState: progressState
                    )
                }
            }
        }
    }
}

private struct CollapsibleToolbarSearchView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    let focusRequestID: UInt64
    let onCommitToResults: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isPresented: $isPresented,
            onCommitToResults: onCommitToResults
        )
    }

    func makeNSView(context: Context) -> SearchContainerView {
        let view = SearchContainerView(coordinator: context.coordinator)
        view.setExpanded(isPresented, animated: false)
        view.updateText(text)
        view.lastHandledFocusRequestID = focusRequestID
        return view
    }

    func updateNSView(_ nsView: SearchContainerView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isPresented = $isPresented
        context.coordinator.onCommitToResults = onCommitToResults

        nsView.updateText(text)

        if nsView.isExpandedState != isPresented {
            nsView.setExpanded(isPresented, animated: true)
            if isPresented {
                nsView.focusTextField()
            }
        }

        if nsView.lastHandledFocusRequestID != focusRequestID {
            nsView.lastHandledFocusRequestID = focusRequestID
            if isPresented {
                nsView.focusTextField()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isPresented: Binding<Bool>
        var onCommitToResults: () -> Void
        weak var containerView: SearchContainerView?
        var hasBegunEditing = false

        init(
            text: Binding<String>,
            isPresented: Binding<Bool>,
            onCommitToResults: @escaping () -> Void
        ) {
            self.text = text
            self.isPresented = isPresented
            self.onCommitToResults = onCommitToResults
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            hasBegunEditing = true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
            containerView?.updateClearButtonVisibility()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard hasBegunEditing,
                  let containerView,
                  containerView.isExpandedState,
                  !containerView.isAnimatingExpansion,
                  let field = obj.object as? NSTextField,
                  field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            hasBegunEditing = false
            DispatchQueue.main.async { [weak self, weak containerView, weak field] in
                guard let self, let containerView, let field else { return }
                let stillEmpty = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isEditingField = field.window?.firstResponder === field.currentEditor() ||
                    field.window?.firstResponder === field
                if stillEmpty && !isEditingField && containerView.isExpandedState {
                    containerView.setExpanded(false, animated: true)
                    self.isPresented.wrappedValue = false
                }
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) ||
               commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onCommitToResults()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                text.wrappedValue = ""
                containerView?.updateText("")
                containerView?.setExpanded(false, animated: true)
                isPresented.wrappedValue = false
                onCommitToResults()
                return true
            }
            return false
        }
    }
}

@MainActor
private final class SearchContainerView: NSView {
    private static let collapsedWidth: CGFloat = 36
    private static let expandedWidth: CGFloat = 196
    private static let controlHeight: CGFloat = 28

    unowned let coordinator: CollapsibleToolbarSearchView.Coordinator
    var isExpandedState = false
    var isAnimatingExpansion = false
    var lastHandledFocusRequestID: UInt64 = 0

    let iconButton = NSButton()
    let textField = NSTextField()
    let clearButton = NSButton()

    private var widthConstraint: NSLayoutConstraint!
    private var iconLeadingConstraint: NSLayoutConstraint!
    private var expandedLayoutConstraints: [NSLayoutConstraint] = []
    private var animationGeneration: UInt64 = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.controlHeight)
    }

    init(coordinator: CollapsibleToolbarSearchView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: NSRect(x: 0, y: 0, width: Self.collapsedWidth, height: Self.controlHeight))
        coordinator.containerView = self
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("toolbar.search.container")

        if #unavailable(macOS 26.0) {
            wantsLayer = true
            layer?.cornerRadius = Self.controlHeight / 2
            layer?.masksToBounds = true
        }

        let searchSymbol = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: String(localized: "Find")
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        iconButton.image = searchSymbol
        iconButton.isBordered = false
        iconButton.bezelStyle = .accessoryBarAction
        iconButton.imagePosition = .imageOnly
        iconButton.contentTintColor = .labelColor
        iconButton.target = self
        iconButton.action = #selector(handleIconClick)
        iconButton.translatesAutoresizingMaskIntoConstraints = false
        iconButton.toolTip = String(localized: "Find")
        iconButton.setAccessibilityIdentifier("toolbar.search.button")

        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.placeholderString = String(localized: "Search")
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.delegate = coordinator
        textField.alphaValue = 0
        textField.isHidden = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityIdentifier("toolbar.search.field")

        let clearSymbol = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "Clear")
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        clearButton.image = clearSymbol
        clearButton.isBordered = false
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(handleClearClick)
        clearButton.alphaValue = 0
        clearButton.isHidden = true
        clearButton.toolTip = String(localized: "Clear")
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setAccessibilityIdentifier("toolbar.search.clear")

        addSubview(iconButton)
        addSubview(textField)
        addSubview(clearButton)

        widthConstraint = widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
        widthConstraint.priority = .required
        iconLeadingConstraint = iconButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9)

        let textLeading = textField.leadingAnchor.constraint(equalTo: iconButton.trailingAnchor, constant: 5)
        let textCenterY = textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        let textTrailing = textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4)
        textTrailing.priority = .defaultHigh
        let clearTrailing = clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)
        clearTrailing.priority = .defaultHigh
        let clearCenterY = clearButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        let clearWidth = clearButton.widthAnchor.constraint(equalToConstant: 16)
        let clearHeight = clearButton.heightAnchor.constraint(equalToConstant: 16)
        expandedLayoutConstraints = [
            textLeading, textCenterY, textTrailing,
            clearTrailing, clearCenterY, clearWidth, clearHeight,
        ]

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.controlHeight),

            iconLeadingConstraint,
            iconButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconButton.widthAnchor.constraint(equalToConstant: 18),
            iconButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @objc private func handleIconClick() {
        if !isExpandedState {
            setExpanded(true, animated: true)
            coordinator.isPresented.wrappedValue = true
        }
        focusTextField()
    }

    @objc private func handleClearClick() {
        textField.stringValue = ""
        coordinator.text.wrappedValue = ""
        updateClearButtonVisibility()
        focusTextField()
    }

    func updateText(_ value: String) {
        if textField.stringValue != value {
            textField.stringValue = value
        }
        updateClearButtonVisibility()
    }

    func updateClearButtonVisibility() {
        let shouldShow = isExpandedState && !textField.stringValue.isEmpty
        clearButton.isHidden = !shouldShow
        clearButton.alphaValue = shouldShow ? 1 : 0
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        isExpandedState = expanded
        animationGeneration &+= 1
        let generation = animationGeneration

        let targetWidth = expanded ? Self.expandedWidth : Self.collapsedWidth
        let targetIconLeading: CGFloat = expanded ? 10 : 9
        iconButton.toolTip = expanded ? nil : String(localized: "Find")
        iconButton.contentTintColor = expanded ? .secondaryLabelColor : .labelColor

        if expanded {
            NSLayoutConstraint.activate(expandedLayoutConstraints)
            textField.isHidden = false
            updateClearButtonVisibility()
        }

        if #unavailable(macOS 26.0) {
            if expanded {
                layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
                layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
                layer?.borderWidth = 0.75
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                layer?.borderWidth = 0
            }
        }

        if !animated {
            isAnimatingExpansion = false
            widthConstraint.constant = targetWidth
            iconLeadingConstraint.constant = targetIconLeading
            textField.alphaValue = expanded ? 1 : 0
            textField.isHidden = !expanded
            if !expanded {
                NSLayoutConstraint.deactivate(expandedLayoutConstraints)
            }
            updateClearButtonVisibility()
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            return
        }

        isAnimatingExpansion = expanded
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            widthConstraint.animator().constant = targetWidth
            iconLeadingConstraint.animator().constant = targetIconLeading
            textField.animator().alphaValue = expanded ? 1 : 0
            if !expanded {
                clearButton.animator().alphaValue = 0
            }
            superview?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.isAnimatingExpansion = false
                if !self.isExpandedState {
                    self.textField.isHidden = true
                    self.clearButton.isHidden = true
                    NSLayoutConstraint.deactivate(self.expandedLayoutConstraints)
                    self.coordinator.hasBegunEditing = false
                } else {
                    self.updateClearButtonVisibility()
                }
                self.invalidateIntrinsicContentSize()
            }
        }
    }

    func focusTextField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isExpandedState, let window = self.window else { return }
            self.textField.isHidden = false
            if window.makeFirstResponder(self.textField) {
                self.coordinator.hasBegunEditing = true
                if let editor = self.textField.currentEditor(), !self.textField.stringValue.isEmpty {
                    editor.selectAll(nil)
                }
            }
        }
    }
}
