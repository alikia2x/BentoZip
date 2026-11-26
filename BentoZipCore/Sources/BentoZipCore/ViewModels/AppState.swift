import SwiftUI
import Observation

/// Resolution selected by the user for a single extraction filename collision.
public enum ExtractConflictResolution: Sendable, Equatable {
    case overwrite
    case skip
    case rename
}

/// Interactive conflict prompt presented when `ExtractConflictPolicy.ask` encounters an existing item.
public struct ExtractConflictPrompt: Identifiable, Sendable {
    public let id: UUID
    public let sourceName: String
    public let destinationURL: URL
    public let isDirectory: Bool
    private let resolver: @MainActor @Sendable (ExtractConflictResolution?, Bool) -> Void

    public init(
        id: UUID = UUID(),
        sourceName: String,
        destinationURL: URL,
        isDirectory: Bool,
        resolver: @escaping @MainActor @Sendable (ExtractConflictResolution?, Bool) -> Void
    ) {
        self.id = id
        self.sourceName = sourceName
        self.destinationURL = destinationURL
        self.isDirectory = isDirectory
        self.resolver = resolver
    }

    @MainActor
    public func resolve(_ resolution: ExtractConflictResolution, applyToAll: Bool = false) {
        resolver(resolution, applyToAll)
    }

    @MainActor
    public func cancel() {
        resolver(nil, false)
    }
}

/// Result of testing archive integrity presented in the UI.
public struct TestArchiveResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let archiveName: String
    public let itemsCount: Int
    public let passed: Bool
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        archiveName: String,
        itemsCount: Int,
        passed: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.archiveName = archiveName
        self.itemsCount = itemsCount
        self.passed = passed
        self.errorMessage = errorMessage
    }
}

/// Snapshot of a parent archive session pushed when drilling into a nested archive.
public struct NestedArchiveFrame: Identifiable, Sendable {
    public let id: UUID
    public let archiveURL: URL
    public let archiveName: String
    public let password: String?
    public let encoding: FilenameEncodingOption
    public let archiveComment: String?
    public let rootNodes: [FileNode]
    public let unwrappedRootPath: String?
    public let navigationNodeIDs: [UUID]
    public let totalSize: Int64
    public let totalEntryCount: Int
    public let totalPackedSize: Int64?
    public let archivePackedSize: Int64?
    public let isArchiveEncrypted: Bool
    public let tempNestedDirectoryURL: URL?

    public init(
        id: UUID = UUID(),
        archiveURL: URL,
        archiveName: String,
        password: String?,
        encoding: FilenameEncodingOption,
        archiveComment: String?,
        rootNodes: [FileNode],
        unwrappedRootPath: String?,
        navigationNodeIDs: [UUID],
        totalSize: Int64,
        totalEntryCount: Int,
        totalPackedSize: Int64?,
        archivePackedSize: Int64? = nil,
        isArchiveEncrypted: Bool,
        tempNestedDirectoryURL: URL?
    ) {
        self.id = id
        self.archiveURL = archiveURL
        self.archiveName = archiveName
        self.password = password
        self.encoding = encoding
        self.archiveComment = archiveComment
        self.rootNodes = rootNodes
        self.unwrappedRootPath = unwrappedRootPath
        self.navigationNodeIDs = navigationNodeIDs
        self.totalSize = totalSize
        self.totalEntryCount = totalEntryCount
        self.totalPackedSize = totalPackedSize
        self.archivePackedSize = archivePackedSize
        self.isArchiveEncrypted = isArchiveEncrypted
        self.tempNestedDirectoryURL = tempNestedDirectoryURL
    }
}

/// Owns a `NotificationCenter` observer token and unregisters it automatically on deallocation.
private final class NotificationObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(name: Notification.Name, queue: OperationQueue?, block: @escaping @Sendable (Notification) -> Void) {
        self.token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue, using: block)
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

@Observable
@MainActor
public class AppState {
    public var mode: ArchiveMode = .empty
    public private(set) var rootNodes: [FileNode] = []
    public private(set) var navigationNodeIDs: [UUID] = []
    private var nodesByID: [UUID: FileNode] = [:]
    public var selectedEntryIDs: Set<UUID> = []
    public var isLoading: Bool = false
    /// Live browse-loading telemetry when opening large archives (e.g. `.tar.gz` / `.tar.xz` outer stream decompression).
    public var browseProgress: Double?
    public var browseStage: ArchiveProgress.Stage = .normal
    public var browseProcessedBytes: Int64 = 0
    public var browseTotalBytes: Int64 = 0
    /// Non-blocking background folder byte-size calculation indicator in `.compress` mode.
    public internal(set) var isCalculatingSizes: Bool = false
    /// Archive-relative paths (e.g. `Folder/sub/file.txt`) removed from staged local folders in `.compress` mode.
    public internal(set) var excludedCompressRelativePaths: Set<String> = []
    var excludedCompressStandardizedPaths: Set<String> = []

    // Incremental reload counters for AppKit NSOutlineView without full-table churn
    public struct NodeUpdateEvent: Sendable {
        public let revision: UInt64
        public let nodeID: UUID
        public let reloadChildren: Bool
    }

    public private(set) var treeStructureRevision: UInt64 = 0
    public private(set) var lastUpdatedNodeID: UUID?
    public private(set) var lastUpdatedNodeReloadChildren: Bool = false
    public private(set) var nodeUpdateRevision: UInt64 = 0
    private var nodeUpdateLog: [NodeUpdateEvent] = []
    private static let maxNodeUpdateLogCount = 256

    public internal(set) var totalSize: Int64 = 0
    /// Archive-level packed size reported by the backend (accurate for solid 7z and compound tar streams).
    public var archivePackedSize: Int64?
    var cachedEntryPackedSize: Int64?
    var cachedContainsEncryptedEntry: Bool = false
    public internal(set) var totalEntryCount: Int = 0

    public var compressionSettings = CompressionSettings()
    public var showInspector: Bool = false
    public var sourceArchiveURL: URL?
    public var archiveComment: String?
    public var lastError: String?

    // Nested archive browsing stack
    public private(set) var nestedArchiveStack: [NestedArchiveFrame] = []
    public var isViewingNestedArchive: Bool { !nestedArchiveStack.isEmpty }
    var activeNestedTempDirectoryURL: URL?

    // External file edit monitoring
    public var pendingExternalEdits: [PendingExternalEdit] = []
    @ObservationIgnored public var onExternalFileModified: ((PendingExternalEdit) -> Void)?
    @ObservationIgnored public let externalEditMonitor = ExternalEditMonitor()

    // Password flow state
    public var archivePassword: String?
    public var needsPasswordPrompt: Bool = false
    public var passwordPromptReason: String?
    public var isPasswordRetryError: Bool = false
    public var pendingPasswordArchiveURL: URL?
    public var pendingPasswordAction: PendingPasswordAction?

    // Validated recent archives (populated asynchronously off the main actor)
    public internal(set) var recentArchiveItems: [RecentArchiveItem] = []

    // User preferences synced with PreferencesManager when available
    public var revealInFinderAfterExtract: Bool = true
    public var unwrapSingleTopDirectory: Bool = true
    public var extractConflictPolicy: ExtractConflictPolicy = .ask
    public var moveArchiveToTrashAfterExtract: Bool = false
    public var closeWindowAfterExtract: Bool = false
    public var stripQuarantineOnExtract: Bool = false
    public var autoTryVaultPasswords: Bool = true
    public var viewMode: BrowserViewMode = .list
    public var showHiddenFiles: Bool = false {
        didSet {
            if showHiddenFiles != oldValue {
                bumpTreeStructureRevision()
            }
        }
    }

    // Search, encoding, conflict prompt, and test result state
    @ObservationIgnored private var suppressSearchRevisionBump = false
    public var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue && !suppressSearchRevisionBump {
                bumpTreeStructureRevision()
            }
        }
    }
    public var isSearchVisible: Bool = false
    public var selectedEncoding: FilenameEncodingOption = .auto
    public internal(set) var unwrappedRootPath: String?
    public var activeConflictPrompt: ExtractConflictPrompt?
    public var testArchiveResult: TestArchiveResult?
    @ObservationIgnored public var onRequestCloseWindow: (() -> Void)?
    @ObservationIgnored public var onResumePreview: (([FileEntry]) -> Void)?

    public var coordinator = CompressionCoordinator()
    public var preferencesManager: PreferencesManager? {
        didSet {
            applyPreferences()
            refreshRecentArchives()
        }
    }

    var loadGeneration: UInt64 = 0
    var loadTask: Task<Void, Never>?
    var pendingAddedURLs: [URL] = []
    var sizeCalculationTask: Task<Void, Never>?
    var pendingSizeTargets: [(id: UUID, url: URL)] = []
    var loadingChildTasks: [UUID: Task<Void, Never>] = [:]
    var recentValidationTask: Task<Void, Never>?
    private var preferencesObserver: NotificationObserverToken?

    public init() {
        externalEditMonitor.onModified = { [weak self] edit in
            self?.enqueuePendingExternalEdit(edit)
        }
        preferencesObserver = NotificationObserverToken(
            name: PreferencesManager.preferencesDidChangeNotification,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handlePreferencesDidChange() }
            } else {
                Task { @MainActor [weak self] in self?.handlePreferencesDidChange() }
            }
        }
    }

    // MARK: - Single-Source-of-Truth Node Accessors

    public var navigationNodes: [FileNode] { navigationNodeIDs.compactMap { nodesByID[$0] } }

    /// Current archive-relative subfolder path based on the deepest active navigation node,
    /// or the unwrapped single top-level directory prefix when viewing an unwrapped archive root.
    public var currentSubfolderPath: String {
        if let raw = navigationNodes.last?.archiveRelativePath {
            return Self.normalizedArchiveRelativePath(raw)
        }
        if let unwrappedRootPath, !unwrappedRootPath.isEmpty {
            return Self.normalizedArchiveRelativePath(unwrappedRootPath)
        }
        return ""
    }

    /// Nodes inside the currently navigated folder (respecting `showHiddenFiles`), ignoring active search.
    public var currentFolderNodes: [FileNode] {
        _ = treeStructureRevision
        let raw: [FileNode]
        if let currentID = navigationNodeIDs.last, let current = nodesByID[currentID] {
            _ = nodeUpdateRevision
            raw = current.children ?? []
        } else {
            raw = rootNodes
        }
        return showHiddenFiles ? raw : raw.filter { !$0.isHidden }
    }

    /// Context-accurate packed size for the current view (root archive, subfolder, or search results).
    public var currentFolderPackedSize: Int64? {
        _ = treeStructureRevision
        _ = nodeUpdateRevision
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if navigationNodes.isEmpty && trimmedQuery.isEmpty {
            return totalPackedSize
        }
        if !navigationNodes.isEmpty && trimmedQuery.isEmpty {
            let sum = Self.recursivePackedSize(of: currentFolderNodes)
            return sum > 0 ? sum : nil
        }
        let matched = displayedNodes
        let matchedIDs = Set(matched.map(\.id))
        let topMatches = matched.filter { node in
            var ancestor = node.parent
            while let current = ancestor {
                if matchedIDs.contains(current.id) { return false }
                ancestor = current.parent
            }
            return true
        }
        let sum = Self.recursivePackedSize(of: topMatches)
        return sum > 0 ? sum : nil
    }

    private static func recursivePackedSize(of nodes: [FileNode]) -> Int64 {
        var total: Int64 = 0
        for node in nodes {
            if node.isDirectory, let children = node.children {
                total += recursivePackedSize(of: children)
            } else if let packed = node.packedSize, packed > 0 {
                total += packed
            }
        }
        return total
    }

    /// Visible immediate children of `node`, respecting `showHiddenFiles`.
    public func visibleChildren(of node: FileNode) -> [FileNode] {
        _ = nodeUpdateRevision
        let raw = node.children ?? []
        return showHiddenFiles ? raw : raw.filter { !$0.isHidden }
    }

    public var displayedNodes: [FileNode] {
        _ = treeStructureRevision
        _ = nodeUpdateRevision
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            return matchingNodes(for: trimmedQuery)
        }
        return currentFolderNodes
    }

    /// Sorted image `FileNode`s for the inline gallery/comic reader.
    /// Returns images in the current folder, or across the entire archive for `.cbz`/`.cbr` or active search.
    public var galleryImageNodes: [FileNode] {
        _ = treeStructureRevision
        _ = nodeUpdateRevision

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = sourceArchiveURL?.pathExtension.lowercased()
        let isComicArchive = (ext == "cbz" || ext == "cbr")

        let candidates: [FileNode]
        if !trimmedQuery.isEmpty {
            candidates = displayedNodes.filter { !$0.isDirectory && InlinePreviewHelper.isImageFile($0.name) }
        } else if isComicArchive {
            var collected: [FileNode] = []
            func walkImages(_ nodes: [FileNode]) {
                for node in nodes {
                    if !showHiddenFiles && node.isHidden {
                        continue
                    }
                    if node.isDirectory {
                        if let children = node.children {
                            walkImages(children)
                        }
                    } else if InlinePreviewHelper.isImageFile(node.name) {
                        collected.append(node)
                    }
                }
            }
            walkImages(rootNodes)
            candidates = collected
        } else {
            candidates = currentFolderNodes.filter { !$0.isDirectory && InlinePreviewHelper.isImageFile($0.name) }
        }

        return candidates.sorted { lhs, rhs in
            let lhsKey = lhs.archiveRelativePath ?? lhs.name
            let rhsKey = rhs.archiveRelativePath ?? rhs.name
            return lhsKey.localizedStandardCompare(rhsKey) == .orderedAscending
        }
    }

    private func matchingNodes(for query: String) -> [FileNode] {
        var matches: [FileNode] = []
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                if !showHiddenFiles && node.isHidden {
                    continue
                }
                let nameMatched = node.name.localizedCaseInsensitiveContains(query)
                let pathMatched = node.archiveRelativePath?.localizedCaseInsensitiveContains(query) ?? false
                if nameMatched || pathMatched {
                    matches.append(node)
                }
                if let children = node.children {
                    walk(children)
                }
            }
        }
        walk(rootNodes)
        return matches
    }

    public var selectedNodes: [FileNode] { selectedEntryIDs.compactMap { nodesByID[$0] } }
    public func node(for id: UUID) -> FileNode? { nodesByID[id] }
    public var canNavigateUp: Bool { !navigationNodeIDs.isEmpty || isViewingNestedArchive }

    // MARK: - Value-Type Compatibility Bridges

    /// Replace the root tree from value-type `FileEntry` snapshots (e.g. engine listings or tests).
    public func setEntries(_ entries: [FileEntry], unwrappedRootPath: String? = nil) {
        self.unwrappedRootPath = unwrappedRootPath.flatMap {
            let clean = Self.normalizedArchiveRelativePath($0)
            return clean.isEmpty ? nil : clean
        }
        replaceRootNodes(entries.map { FileNode(entry: $0) })
    }

    public var fileEntries: [FileEntry] {
        get {
            _ = (treeStructureRevision, nodeUpdateRevision)
            return rootNodes.map { $0.toFileEntry(includeChildren: true) }
        }
        set { setEntries(newValue) }
    }

    public var displayedEntries: [FileEntry] {
        _ = (treeStructureRevision, nodeUpdateRevision)
        return displayedNodes.map { $0.toFileEntry(includeChildren: true) }
    }

    public var navigationPath: [FileEntry] {
        get {
            _ = (treeStructureRevision, nodeUpdateRevision)
            return navigationNodes.map { $0.toFileEntry(includeChildren: true) }
        }
        set {
            navigationNodeIDs = newValue.map { resolveOrRegisterNode(nodesByID[$0.id] ?? FileNode(entry: $0)).id }
            bumpTreeStructureRevision()
        }
    }

    public var selectedEntries: [FileEntry] {
        _ = nodeUpdateRevision
        return selectedNodes.map { $0.toFileEntry(includeChildren: true) }
    }

    // MARK: - Internal Single-Source-of-Truth Tree Primitives

    func replaceRootNodes(_ nodes: [FileNode]) {
        rootNodes = nodes
        nodesByID.removeAll(keepingCapacity: true)
        excludedCompressRelativePaths.removeAll(keepingCapacity: true)
        excludedCompressStandardizedPaths.removeAll(keepingCapacity: true)
        registerSubtrees(nodes)
        navigationNodeIDs.removeAll { nodesByID[$0] == nil }
        selectedEntryIDs = selectedEntryIDs.filter { nodesByID[$0] != nil }
        recomputeEntryMetrics()
        bumpTreeStructureRevision()
    }

    func appendRootNodes(_ newNodes: [FileNode]) {
        rootNodes = Self.sortedNodes(rootNodes + newNodes)
        registerSubtrees(newNodes)
        recomputeEntryMetrics()
        bumpTreeStructureRevision()
    }

    func updateNodeSize(id: UUID, bytes: Int64) {
        guard let node = nodesByID[id] else { return }
        let delta = bytes - node.size
        node.size = bytes
        if !node.isFromArchive && node.parent == nil { totalSize += delta }
        recordNodeUpdate(id: id, reloadChildren: false)
    }

    func attachLoadedChildren(_ children: [FileNode], to id: UUID, recordUpdate: Bool = true) {
        guard let node = nodesByID[id] else { return }
        node.children?.forEach(unregisterSubtree)
        children.forEach { $0.parent = node }
        node.children = children
        node.hasLoadedChildren = true
        registerSubtrees(children)
        if recordUpdate { recordNodeUpdate(id: id, reloadChildren: true) }
    }

    /// Removes top-level staged items or nested items inside staged local folders.
    /// Returns any root directories whose sizes should be recomputed after nested directory removal.
    @discardableResult
    func removeNodesInTree(matching ids: Set<UUID>) -> [(id: UUID, url: URL)] {
        guard !ids.isEmpty else { return [] }

        // Skip descendants whose ancestor is already targeted for removal.
        let effectiveIDs = Set(ids.filter { id in
            guard let node = nodesByID[id] else { return false }
            var ancestor = node.parent
            while let current = ancestor {
                if ids.contains(current.id) { return false }
                ancestor = current.parent
            }
            return true
        })
        guard !effectiveIDs.isEmpty else { return [] }

        var removedRoot = false
        var updatedParentIDs: [UUID] = []
        var updatedParentSet: Set<UUID> = []
        var rootsNeedingResizing: [UUID: URL] = [:]

        // 1. Remove matching root nodes
        var removedRootPrefixes: [(relPrefix: String, pathPrefix: String)] = []
        rootNodes.removeAll { node in
            guard effectiveIDs.contains(node.id) else { return false }
            let rootName = node.url.lastPathComponent
            let rootPath = node.url.standardizedFileURL.path
            removedRootPrefixes.append((rootName + "/", rootPath + "/"))
            unregisterSubtree(node)
            removedRoot = true
            return true
        }

        if !removedRootPrefixes.isEmpty {
            excludedCompressRelativePaths = excludedCompressRelativePaths.filter { rel in
                !removedRootPrefixes.contains { rel.hasPrefix($0.relPrefix) }
            }
            excludedCompressStandardizedPaths = excludedCompressStandardizedPaths.filter { path in
                !removedRootPrefixes.contains { path.hasPrefix($0.pathPrefix) }
            }
        }

        // 2. Remove matching nested nodes from their parent and record compress exclusions
        for id in effectiveIDs {
            guard let node = nodesByID[id], let parent = node.parent else { continue }
            var rootAncestor = parent
            while let next = rootAncestor.parent {
                rootAncestor = next
            }

            if !node.isFromArchive {
                let standardizedNodePath = node.url.standardizedFileURL.path
                excludedCompressStandardizedPaths.insert(standardizedNodePath)
                if let archiveRelPath = Self.compressArchiveRelativePath(for: node, under: rootAncestor) {
                    excludedCompressRelativePaths.insert(archiveRelPath)
                }

                if node.size > 0 {
                    let newRootSize = max(0, rootAncestor.size - node.size)
                    let delta = newRootSize - rootAncestor.size
                    rootAncestor.size = newRootSize
                    totalSize = max(0, totalSize + delta)
                    if !removedRoot {
                        recordNodeUpdate(id: rootAncestor.id, reloadChildren: false)
                    }
                } else if node.isDirectory {
                    rootsNeedingResizing[rootAncestor.id] = rootAncestor.url
                }
            }

            parent.children?.removeAll { $0.id == node.id }
            unregisterSubtree(node)
            if updatedParentSet.insert(parent.id).inserted {
                updatedParentIDs.append(parent.id)
            }
        }

        guard removedRoot || !updatedParentIDs.isEmpty else { return [] }

        let oldNavCount = navigationNodeIDs.count
        navigationNodeIDs.removeAll { nodesByID[$0] == nil }
        let navigationChanged = navigationNodeIDs.count != oldNavCount
        selectedEntryIDs = selectedEntryIDs.filter { nodesByID[$0] != nil }

        if removedRoot || navigationChanged {
            recomputeEntryMetrics()
            bumpTreeStructureRevision()
        } else {
            for parentID in updatedParentIDs {
                recordNodeUpdate(id: parentID, reloadChildren: true)
            }
        }

        return rootsNeedingResizing.map { (id: $0.key, url: $0.value) }
    }

    private static func compressArchiveRelativePath(for node: FileNode, under root: FileNode) -> String? {
        let rootPath = root.url.standardizedFileURL.path
        let nodePath = node.url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard nodePath.hasPrefix(prefix) else { return nil }
        let suffix = String(nodePath.dropFirst(prefix.count))
        guard !suffix.isEmpty else { return nil }
        let rootName = root.url.lastPathComponent
        return rootName.isEmpty ? suffix : "\(rootName)/\(suffix)"
    }

    func resolveOrRegisterNode(_ node: FileNode) -> FileNode {
        if let existing = nodesByID[node.id] { return existing }
        registerSubtrees([node])
        return node
    }

    func pushNavigationNode(id: UUID) {
        clearSearchWithoutRevisionBump()
        navigationNodeIDs.append(id)
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    func popNavigationNode() {
        let hadSearch = !searchQuery.isEmpty || isSearchVisible
        guard !navigationNodeIDs.isEmpty || hadSearch else { return }
        clearSearchWithoutRevisionBump()
        if !navigationNodeIDs.isEmpty {
            navigationNodeIDs.removeLast()
        }
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    func truncateNavigation(to level: Int) {
        clearSearchWithoutRevisionBump()
        if level <= 0 {
            navigationNodeIDs.removeAll()
        } else {
            navigationNodeIDs.removeLast(navigationNodeIDs.count - min(level, navigationNodeIDs.count))
        }
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    private func clearSearchWithoutRevisionBump() {
        suppressSearchRevisionBump = true
        defer { suppressSearchRevisionBump = false }
        if !searchQuery.isEmpty {
            searchQuery = ""
        }
        if isSearchVisible {
            isSearchVisible = false
        }
    }

    func clearNavigationAndSelection() {
        navigationNodeIDs.removeAll()
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    /// Restore navigation stack to the folder matching `targetPath` after refreshing an archive tree.
    func restoreNavigationPath(matchingArchiveRelativePath targetPath: String) {
        let cleanTarget = Self.normalizedArchiveRelativePath(targetPath)
        guard !cleanTarget.isEmpty else {
            clearNavigationAndSelection()
            return
        }

        var pathIDs: [UUID] = []
        var searchPool = rootNodes
        while let match = searchPool.first(where: { node in
            guard node.isDirectory, let rel = node.archiveRelativePath else { return false }
            let cleanNode = Self.normalizedArchiveRelativePath(rel)
            return cleanTarget == cleanNode || cleanTarget.hasPrefix(cleanNode + "/")
        }) {
            pathIDs.append(match.id)
            let cleanNode = Self.normalizedArchiveRelativePath(match.archiveRelativePath ?? "")
            if cleanNode == cleanTarget {
                break
            }
            searchPool = match.children ?? []
        }

        navigationNodeIDs = pathIDs
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    private static func normalizedArchiveRelativePath(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        return s == "." ? "" : s
    }

    /// Returns all incremental node updates after `revision`, or `nil` if the buffer overflowed
    /// (in which case the caller should fall back to `reloadData()`).
    public func nodeUpdates(since revision: UInt64) -> [NodeUpdateEvent]? {
        guard revision < nodeUpdateRevision else { return [] }
        guard let oldest = nodeUpdateLog.first, revision >= oldest.revision - 1 else {
            return nil
        }
        return nodeUpdateLog.filter { $0.revision > revision }
    }

    private func bumpTreeStructureRevision() {
        lastUpdatedNodeID = nil
        lastUpdatedNodeReloadChildren = false
        nodeUpdateLog.removeAll(keepingCapacity: true)
        treeStructureRevision &+= 1
    }

    private func recordNodeUpdate(id: UUID, reloadChildren: Bool) {
        lastUpdatedNodeID = id
        lastUpdatedNodeReloadChildren = reloadChildren
        nodeUpdateRevision &+= 1
        nodeUpdateLog.append(NodeUpdateEvent(
            revision: nodeUpdateRevision,
            nodeID: id,
            reloadChildren: reloadChildren
        ))
        if nodeUpdateLog.count > Self.maxNodeUpdateLogCount {
            nodeUpdateLog.removeFirst(nodeUpdateLog.count - Self.maxNodeUpdateLogCount)
        }
    }

    private func registerSubtrees(_ nodes: [FileNode]) {
        for node in nodes {
            nodesByID[node.id] = node
            if let children = node.children { registerSubtrees(children) }
        }
    }

    private func unregisterSubtree(_ node: FileNode) {
        nodesByID.removeValue(forKey: node.id)
        node.children?.forEach(unregisterSubtree)
    }

    // MARK: - Nested Archive Stack & External Edits

    func pushNestedArchiveFrame(newTempDirectoryURL: URL?) {
        guard let archiveURL = sourceArchiveURL else { return }
        let frame = NestedArchiveFrame(
            archiveURL: archiveURL,
            archiveName: archiveURL.lastPathComponent,
            password: archivePassword,
            encoding: selectedEncoding,
            archiveComment: archiveComment,
            rootNodes: rootNodes,
            unwrappedRootPath: unwrappedRootPath,
            navigationNodeIDs: navigationNodeIDs,
            totalSize: totalSize,
            totalEntryCount: totalEntryCount,
            totalPackedSize: totalPackedSize,
            archivePackedSize: archivePackedSize,
            isArchiveEncrypted: isArchiveEncrypted,
            tempNestedDirectoryURL: activeNestedTempDirectoryURL
        )
        nestedArchiveStack.append(frame)
        activeNestedTempDirectoryURL = newTempDirectoryURL
    }

    /// Pop back to a parent archive from the nested archive stack (`nil` pops one level).
    public func popNestedArchive(toStackIndex targetIndex: Int? = nil) {
        guard !nestedArchiveStack.isEmpty else { return }
        let destinationIndex = targetIndex ?? (nestedArchiveStack.count - 1)
        guard nestedArchiveStack.indices.contains(destinationIndex) else { return }

        coordinator.cancelBrowse()
        activeConflictPrompt?.cancel()
        activeConflictPrompt = nil

        var tempDirsToDelete: [URL] = []
        if let activeNestedTempDirectoryURL {
            tempDirsToDelete.append(activeNestedTempDirectoryURL)
        }

        let targetFrame = nestedArchiveStack[destinationIndex]
        if destinationIndex + 1 < nestedArchiveStack.count {
            for idx in (destinationIndex + 1)..<nestedArchiveStack.count {
                if let tempDir = nestedArchiveStack[idx].tempNestedDirectoryURL {
                    tempDirsToDelete.append(tempDir)
                }
            }
        }
        nestedArchiveStack.removeSubrange(destinationIndex..<nestedArchiveStack.count)
        activeNestedTempDirectoryURL = targetFrame.tempNestedDirectoryURL

        if !tempDirsToDelete.isEmpty {
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                for dir in tempDirsToDelete {
                    try? fm.removeItem(at: dir)
                }
            }
        }

        clearSearchWithoutRevisionBump()
        lastError = nil
        testArchiveResult = nil
        cancelPasswordPrompt()

        mode = .browseArchive
        sourceArchiveURL = targetFrame.archiveURL
        archivePassword = targetFrame.password
        selectedEncoding = targetFrame.encoding
        archiveComment = targetFrame.archiveComment
        unwrappedRootPath = targetFrame.unwrappedRootPath
        archivePackedSize = targetFrame.archivePackedSize

        replaceRootNodes(targetFrame.rootNodes)
        navigationNodeIDs = targetFrame.navigationNodeIDs.filter { nodesByID[$0] != nil }
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    func cleanupNestedArchives() {
        var tempDirsToDelete: [URL] = []
        if let activeNestedTempDirectoryURL {
            tempDirsToDelete.append(activeNestedTempDirectoryURL)
            self.activeNestedTempDirectoryURL = nil
        }
        for frame in nestedArchiveStack {
            if let dir = frame.tempNestedDirectoryURL {
                tempDirsToDelete.append(dir)
            }
        }
        nestedArchiveStack.removeAll()
        if !tempDirsToDelete.isEmpty {
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                for dir in tempDirsToDelete {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }

    func enqueuePendingExternalEdit(_ edit: PendingExternalEdit) {
        let stdTemp = edit.tempURL.standardizedFileURL
        let stdArchive = edit.archiveURL.standardizedFileURL
        if let existingIndex = pendingExternalEdits.firstIndex(where: {
            $0.tempURL.standardizedFileURL == stdTemp &&
            $0.archiveURL.standardizedFileURL == stdArchive &&
            $0.archiveRelativePath == edit.archiveRelativePath
        }) {
            pendingExternalEdits[existingIndex] = edit
        } else {
            pendingExternalEdits.append(edit)
        }
        onExternalFileModified?(edit)
    }

    public func dismissExternalEdit(_ edit: PendingExternalEdit) {
        pendingExternalEdits.removeAll { $0.id == edit.id }
        externalEditMonitor.acknowledgeChange(at: edit.tempURL)
    }
}
