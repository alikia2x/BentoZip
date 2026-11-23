import SwiftUI
import Observation

@Observable
@MainActor
public class ProgressState {
    public var isOperationInProgress: Bool = false
    public var operationProgress: Double = 0.0
    public var operationDescription: String = ""
    public var currentFileName: String = ""
    public var shouldDismiss: Bool = false
    public var isCancellable: Bool = true
    public var onCancel: (() -> Void)?

    public init() {}

    /// Request cancellation of the active operation, if any.
    public func cancel() {
        onCancel?()
    }

    /// Reset all progress fields cleanly before starting or after finishing an operation.
    public func reset(description: String = "") {
        isOperationInProgress = false
        operationProgress = 0.0
        operationDescription = description
        currentFileName = ""
        shouldDismiss = false
        isCancellable = true
        onCancel = nil
    }
}
