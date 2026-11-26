import AppKit
import BentoZipCore
import SwiftUI

struct ImageGallerySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let initialNodeID: UUID?

    @State private var currentIndex: Int = 0
    @State private var imagesByID: [UUID: NSImage] = [:]
    @State private var zoomScale: CGFloat = 1.0
    @State private var isLoadingCurrent: Bool = false
    @State private var loadErrorMessage: String?
    @State private var loadTasks: [UUID: Task<Void, Never>] = [:]

    private var nodes: [FileNode] {
        appState.galleryImageNodes
    }

    private var currentNode: FileNode? {
        guard nodes.indices.contains(currentIndex) else { return nil }
        return nodes[currentIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            viewerCanvas
        }
        .frame(minWidth: 780, idealWidth: 920, minHeight: 540, idealHeight: 660)
        .preferredColorScheme(.dark)
        .onAppear {
            if let initialNodeID,
               let idx = nodes.firstIndex(where: { $0.id == initialNodeID }) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
            loadCurrentAndAdjacent()
        }
        .onChange(of: currentIndex) { _, _ in
            zoomScale = 1.0
            loadCurrentAndAdjacent()
        }
        .onDisappear {
            for task in loadTasks.values {
                task.cancel()
            }
            loadTasks.removeAll()
        }
        .onKeyPress(.leftArrow) {
            showPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            showNext()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in
            zoomIn()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "-_")) { _ in
            zoomOut()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in
            zoomScale = 1.0
            return .handled
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            if let currentNode {
                Text(currentNode.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !nodes.isEmpty {
                Text(String(localized: "\(currentIndex + 1) / \(nodes.count)"))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(zoomScale <= 0.25)
                .help("Zoom Out")

                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42)

                Button {
                    zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(zoomScale >= 4.0)
                .help("Zoom In")

                Button("Reset") {
                    zoomScale = 1.0
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(abs(zoomScale - 1.0) < 0.01)
            }

            Divider()
                .frame(height: 16)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }

    private var viewerCanvas: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.08)

                if let node = currentNode {
                    if let image = imagesByID[node.id] {
                        if abs(zoomScale - 1.0) < 0.01 {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: geo.size.width - 24, maxHeight: geo.size.height - 24)
                        } else {
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(
                                        width: max(120, (geo.size.width - 24) * zoomScale),
                                        height: max(120, (geo.size.height - 24) * zoomScale)
                                    )
                                    .padding(12)
                            }
                        }
                    } else if isLoadingCurrent {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Text(loadErrorMessage ?? String(localized: "Unable to load image"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No images available")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                if nodes.count > 1 {
                    HStack {
                        navigationOverlayButton(
                            systemName: "chevron.left",
                            disabled: currentIndex <= 0,
                            action: showPrevious
                        )
                        Spacer()
                        navigationOverlayButton(
                            systemName: "chevron.right",
                            disabled: currentIndex >= nodes.count - 1,
                            action: showNext
                        )
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    private func navigationOverlayButton(
        systemName: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func showPrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func showNext() {
        guard currentIndex < nodes.count - 1 else { return }
        currentIndex += 1
    }

    private func zoomIn() {
        zoomScale = min(4.0, zoomScale + 0.25)
    }

    private func zoomOut() {
        zoomScale = max(0.25, zoomScale - 0.25)
    }

    private func loadCurrentAndAdjacent() {
        guard nodes.indices.contains(currentIndex) else { return }
        let targetIndices = [currentIndex, currentIndex + 1, currentIndex - 1]
            .filter { nodes.indices.contains($0) }

        for idx in targetIndices {
            let node = nodes[idx]
            if imagesByID[node.id] != nil || loadTasks[node.id] != nil {
                continue
            }
            let isPrimary = (idx == currentIndex)
            if isPrimary {
                isLoadingCurrent = true
                loadErrorMessage = nil
            }
            let entry = node.toFileEntry()
            let isFromArchive = node.isFromArchive
            let localURL = node.url
            let archiveURL = appState.sourceArchiveURL
            let password = appState.archivePassword
            let encoding = appState.selectedEncoding.iconvName

            loadTasks[node.id] = Task {
                defer { loadTasks.removeValue(forKey: node.id) }
                do {
                    let targetURL: URL
                    if !isFromArchive {
                        targetURL = localURL
                    } else {
                        guard let archiveURL,
                              let extracted = try await DragDropManager.shared.prepareForDragThrowing(
                                  entry,
                                  sourceArchiveURL: archiveURL,
                                  password: password,
                                  encoding: encoding
                              ) else {
                            if isPrimary {
                                isLoadingCurrent = false
                                loadErrorMessage = String(localized: "Unable to extract image")
                            }
                            return
                        }
                        targetURL = extracted
                    }

                    guard !Task.isCancelled else { return }
                    let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                        guard let data = try? Data(contentsOf: targetURL) else { return nil }
                        return NSImage(data: data)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let decoded {
                        imagesByID[node.id] = decoded
                    } else if isPrimary {
                        loadErrorMessage = String(localized: "Unsupported image format")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if isPrimary {
                        loadErrorMessage = error.localizedDescription
                    }
                }
                if isPrimary {
                    isLoadingCurrent = false
                }
            }
        }
    }
}
