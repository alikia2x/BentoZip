import BentoZipCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    @State private var showErrorAlert = false
    @State private var showToolbarDeleteConfirmation = false
    @State private var isTargeted = false

    private var canAcceptFileDrop: Bool {
        appState.mode == .compress || appState.isWritableArchive
    }

    private var windowSubtitle: String {
        switch appState.mode {
        case .empty:
            return ""
        case .compress:
            return "准备压缩 \(appState.fileEntries.count) 个项目"
        case .browseArchive:
            return appState.sourceArchiveURL?.lastPathComponent ?? ""
        }
    }

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            switch appState.mode {
            case .empty:
                EmptyStateView()
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            case .compress, .browseArchive:
                fileBrowsingView
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.snappy(duration: 0.22), value: appState.mode)
        .navigationTitle("BentoZip")
        .navigationSubtitle(windowSubtitle)
        .inspector(isPresented: $appState.showInspector) {
            CompressionSettingsView()
                .environment(appState)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarCommands(showDeleteConfirmation: $showToolbarDeleteConfirmation)
        }
        .disabled(progressState.isOperationInProgress)
        .onOpenURL { url in
            Task {
                await appState.handleDroppedURLs([url])
            }
        }
        .onChange(of: appState.lastError) { _, newValue in
            showErrorAlert = newValue != nil
        }
        .sheet(isPresented: $appState.needsPasswordPrompt) {
            PasswordPromptSheet { password in
                await appState.coordinator.submitPassword(
                    password,
                    appState: appState,
                    progressState: progressState,
                    openWindow: openWindow
                )
            }
            .environment(appState)
            .interactiveDismissDisabled(appState.isLoading)
        }
        .alert("操作失败", isPresented: $showErrorAlert) {
            Button("确定") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
        .confirmationDialog(
            "确定从压缩包中删除所选的 \(appState.selectedEntries.count) 个项目吗？",
            isPresented: $showToolbarDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                let entriesToDelete = appState.selectedEntries
                Task {
                    await appState.coordinator.removeEntries(
                        appState: appState,
                        entries: entriesToDelete,
                        progressState: progressState,
                        openWindow: openWindow
                    )
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将修改原压缩包文件且不可撤销。")
        }
    }

    private var fileBrowsingView: some View {
        VStack(spacing: 0) {
            BreadcrumbView()
            FileListView()
            StatusBarView()
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty, canAcceptFileDrop else { return false }
            if appState.mode == .compress {
                appState.addEntries(from: items)
                return true
            } else if appState.isWritableArchive {
                Task {
                    await appState.coordinator.addEntries(
                        appState: appState,
                        urls: items,
                        progressState: progressState,
                        openWindow: openWindow
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
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.06))
                        )
                        .padding(6)

                    Label(
                        appState.mode == .browseArchive ? "松开以添加到压缩包" : "松开以添加到压缩列表",
                        systemImage: "plus.circle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.18), value: isTargeted)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(ProgressState())
}
