import SwiftUI
import Observation

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
    public var lastError: String?

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

    public var displayedNodes: [FileNode] {
        _ = treeStructureRevision
        if let currentID = navigationNodeIDs.last, let current = nodesByID[currentID] {
            _ = nodeUpdateRevision
            return current.children ?? []
        }
        return rootNodes
    }

    public var selectedNodes: [FileNode] { selectedEntryIDs.compactMap { nodesByID[$0] } }
    public func node(for id: UUID) -> FileNode? { nodesByID[id] }
    public var canNavigateUp: Bool { !navigationNodeIDs.isEmpty }

    // MARK: - Value-Type Compatibility Bridges

    /// Replace the root tree from value-type `FileEntry` snapshots (e.g. engine listings or tests).
    public func setEntries(_ entries: [FileEntry]) {
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

    func removeRootNodes(matching ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var removedAny = false
        rootNodes.removeAll { node in
            guard ids.contains(node.id) else { return false }
            unregisterSubtree(node)
            removedAny = true
            return true
        }
        guard removedAny else { return }
        navigationNodeIDs.removeAll { nodesByID[$0] == nil }
        selectedEntryIDs = selectedEntryIDs.filter { nodesByID[$0] != nil }
        recomputeEntryMetrics()
        bumpTreeStructureRevision()
    }

    func resolveOrRegisterNode(_ node: FileNode) -> FileNode {
        if let existing = nodesByID[node.id] { return existing }
        registerSubtrees([node])
        return node
    }

    func pushNavigationNode(id: UUID) {
        navigationNodeIDs.append(id)
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    func popNavigationNode() {
        guard !navigationNodeIDs.isEmpty else { return }
        navigationNodeIDs.removeLast()
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    func truncateNavigation(to level: Int) {
        if level <= 0 {
            navigationNodeIDs.removeAll()
        } else {
            navigationNodeIDs.removeLast(navigationNodeIDs.count - min(level, navigationNodeIDs.count))
        }
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
    }

    func clearNavigationAndSelection() {
        navigationNodeIDs.removeAll()
        selectedEntryIDs.removeAll()
        bumpTreeStructureRevision()
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
}
