import Foundation

enum OperationStatus: String, Sendable {
    case idle = "Idle"
    case running = "Running"
    case completed = "Succeeded"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

struct OperationProgress: Sendable, Equatable {
    let message: String
    /// nil means indeterminate. Only report a fraction when the operation can measure it.
    let fraction: Double?

    init(message: String, fraction: Double? = nil) {
        self.message = message
        self.fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
}
typealias ProgressHandler = @Sendable (OperationProgress) async -> Void
