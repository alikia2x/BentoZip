import BentoZipCore
import CoreSpotlight
import Foundation
import os

private final class LockedSpotlightMetadata: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<ArchiveSpotlightMetadata?>(initialState: nil)

    func set(_ value: ArchiveSpotlightMetadata) {
        lock.withLock { $0 = value }
    }

    func get() -> ArchiveSpotlightMetadata? {
        lock.withLock { $0 }
    }
}

final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = LockedSpotlightMetadata()

        Task.detached(priority: .userInitiated) {
            let metadata = await ArchiveQuickPreviewFormatter.shared.extractSpotlightMetadata(for: contentURL)
            resultBox.set(metadata)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + .seconds(10))
        guard waitResult == .success, let metadata = resultBox.get() else {
            return
        }

        attributes.kind = metadata.formatName
        if !metadata.descriptionText.isEmpty {
            attributes.contentDescription = metadata.descriptionText
            attributes.information = metadata.descriptionText
        }
        if !metadata.searchableText.isEmpty {
            attributes.textContent = metadata.searchableText
        }
    }
}
