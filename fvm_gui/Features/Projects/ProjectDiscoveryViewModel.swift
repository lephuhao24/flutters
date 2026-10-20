import Foundation
import Observation

@MainActor @Observable final class ProjectDiscoveryViewModel {
    private(set) var status: OperationStatus = .idle
    private(set) var progress: OperationProgress?
    private(set) var projects: [FlutterProject] = []
    private(set) var issues: [ProjectDiscoveryIssue] = []
    private(set) var scannedDirectories = 0
    private(set) var error: String?
    var selection = Set<String>()
    private let service: any ProjectDiscovering
    private var task: Task<Void, Never>?
    private var onFinish: (@MainActor (Date?) -> Void)?

    init(service: any ProjectDiscovering = ProjectDiscoveryService()) { self.service = service }

    func scan(roots: [URL], maximumDepth: Int, ignoredPaths: Set<String>, onFinish: @escaping @MainActor (Date?) -> Void) {
        guard task == nil else { return }
        self.onFinish = onFinish
        status = .running
        progress = OperationProgress(message: "Preparing scan…")
        projects = []
        issues = []
        scannedDirectories = 0
        error = nil
        selection = []
        task = Task { [weak self, service] in
            guard let self else { return }
            defer { task = nil }
            do {
                let result = try await service.scan(roots: roots, maximumDepth: maximumDepth, ignoredPaths: ignoredPaths) { update in
                    await MainActor.run { [weak self] in self?.progress = update }
                }
                try Task.checkCancellation()
                projects = result.projects
                issues = result.issues
                scannedDirectories = result.scannedDirectories
                status = .completed
                progress = OperationProgress(message: "Scanned \(result.scannedDirectories) folders · found \(result.projects.count) projects")
                self.onFinish?(Date())
            } catch is CancellationError {
                status = .cancelled
                progress = OperationProgress(message: "Scan cancelled.")
                self.onFinish?(nil)
            } catch {
                status = .failed
                self.error = error.localizedDescription
                progress = nil
                self.onFinish?(nil)
            }
        }
    }

    func cancel() { task?.cancel() }
    func wait() async { await task?.value }
    func remove(_ project: FlutterProject) {
        projects.removeAll { $0.path == project.path }
        selection.remove(project.path)
    }
}
