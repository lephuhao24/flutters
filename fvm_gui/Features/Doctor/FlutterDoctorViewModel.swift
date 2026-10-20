import Foundation
import Observation

@MainActor @Observable final class FlutterDoctorViewModel {
    private let service: FlutterDoctorService
    private let activity: ActivityStore
    private var task: Task<Void, Never>?
    private(set) var report: FlutterDoctorReport?
    private(set) var isRunning = false
    private(set) var operationID: UUID?
    private(set) var activeProjectPath: String?

    init(service: FlutterDoctorService, activity: ActivityStore) {
        self.service = service
        self.activity = activity
    }

    func configure(fvm: (any FVMService)?) async {
        await service.configure(fvm: fvm)
    }

    func run(sdk: FlutterSDK?, project: FlutterProject? = nil) {
        guard !isRunning else { return }
        let id = UUID()
        operationID = id
        activeProjectPath = project.map { Self.canonicalPath($0.path) }
        isRunning = true
        task = Task { [weak self, service, activity] in
            let result = await service.inspect(sdk: sdk, project: project, operationID: id, activity: activity)
            guard let self, self.operationID == id else { return }
            self.report = result
            self.isRunning = false
            self.operationID = nil
            self.activeProjectPath = nil
            self.task = nil
        }
    }

    func runProject(_ project: FlutterProject, installedSDKs: [FlutterSDK]) {
        let requestedVersion = project.effectiveVersion
        let selectedSDK = requestedVersion.flatMap { version in
            installedSDKs.first { $0.name == version } ?? installedSDKs.first { $0.flutterSdkVersion == version }
        } ?? (requestedVersion == nil ? installedSDKs.first(where: \.isGlobal) : nil)
        run(sdk: selectedSDK, project: project)
    }

    func isRunning(for project: FlutterProject) -> Bool {
        isRunning && activeProjectPath == Self.canonicalPath(project.path)
    }

    func cancel() { task?.cancel() }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
