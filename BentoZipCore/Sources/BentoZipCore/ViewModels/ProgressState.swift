import SwiftUI
import Observation

@Observable
@MainActor
public class ProgressState {
    public var isOperationInProgress: Bool = false
    public var operationProgress: Double = 0.0
    public var operationDescription: String = ""
    public var shouldDismiss: Bool = false

    public init() {}
}