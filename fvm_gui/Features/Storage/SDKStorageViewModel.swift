import Foundation
import Observation

enum SDKStorageSort: String, CaseIterable, Identifiable {
    case version = "Version"
    case diskUsage = "Disk Usage"
    case projectReferences = "Project References"
    var id: String { rawValue }
}

@MainActor @Observable final class SDKStorageViewModel {
    private(set) var analysis: SDKStorageAnalysis?
    private(set) var status: OperationStatus = .idle
    private(set) var progress: OperationProgress?
    private(set) var error: String?
    var sort: SDKStorageSort = .diskUsage
    private let service: any SDKStorageServicing
    private var task: Task<Void, Never>?

    init(service: any SDKStorageServicing = SDKStorageService()) { self.service = service }

    var sortedItems: [SDKStorageItem] {
        let items = analysis?.items ?? []
        return switch sort {
        case .version: items.sorted { $0.version.localizedStandardCompare($1.version) == .orderedAscending }
        case .diskUsage: items.sorted { $0.measuredSize > $1.measuredSize }
        case .projectReferences: items.sorted { $0.projectReferenceCount > $1.projectReferenceCount }
        }
    }

    func refresh(sdks: [FlutterSDK], registeredProjects: [FlutterProject], discoveredProjects: [FlutterProject], force: Bool = false) {
        guard task == nil else { return }
        status = .running
        error = nil
        progress = OperationProgress(message: "Measuring installed SDKs…")
        task = Task { [weak self, service] in
            guard let self else { return }
            defer { task = nil }
            do {
                try Task.checkCancellation()
                let result = try await service.analyze(sdks: sdks, registeredProjects: registeredProjects,
                                                       discoveredProjects: discoveredProjects, forceRefresh: force)
                try Task.checkCancellation()
                analysis = result
                status = .completed
                progress = OperationProgress(message: "Measured \(result.installedSDKCount) installed SDKs.")
            } catch is CancellationError {
                status = .cancelled
                progress = OperationProgress(message: "Storage scan cancelled.")
            } catch {
                status = .failed
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }

    func cancel() { task?.cancel() }
    func wait() async { await task?.value }
}
