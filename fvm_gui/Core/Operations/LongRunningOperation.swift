import Foundation
import Observation

/// One UI-owned operation. Cancellation keeps the running state until cleanup completes.
/// Services called by the action own blocking work on their own actors.
@MainActor @Observable final class LongRunningOperation {
    private(set) var status: OperationStatus = .idle
    private(set) var progress: OperationProgress?
    private(set) var failure: (any Error)?
    private(set) var cancelling = false
    private var task: Task<Void, Never>?

    @discardableResult
    func start(_ action: @escaping @MainActor @Sendable (ProgressHandler) async throws -> Void) -> Bool {
        guard task == nil else { return false }
        status = .running
        failure = nil
        progress = nil
        cancelling = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; cancelling = false }
            do {
                // Always enter the action so caller-owned UI cleanup also runs on immediate cancellation.
                try await action { [weak self] update in await self?.report(update) }
                try Task.checkCancellation()
                status = .completed
            } catch is CancellationError {
                status = .cancelled
            } catch {
                failure = error
                status = .failed
            }
        }
        return true
    }

    func cancel() {
        guard task != nil else { return }
        cancelling = true
        task?.cancel()
    }

    func wait() async { await task?.value }

    private func report(_ progress: OperationProgress) {
        guard status == .running, !cancelling else { return }
        self.progress = progress
    }
}
