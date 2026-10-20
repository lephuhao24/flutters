import Foundation
import Observation

@MainActor @Observable final class ProjectDashboardViewModel {
    let ideOpening: ProjectIDEOpeningService
    private let actions: ProjectQuickActionService
    private let activity: ActivityStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var runningActions: [String: Set<ProjectFlutterCommand>] = [:]
    var error: String?

    init(actions: ProjectQuickActionService, activity: ActivityStore,
         ideOpening: ProjectIDEOpeningService = ProjectIDEOpeningService()) {
        self.actions = actions
        self.activity = activity
        self.ideOpening = ideOpening
    }

    func configure(fvm: (any FVMService)?) async { await actions.configure(fvm: fvm) }

    func isRunning(_ command: ProjectFlutterCommand, for project: FlutterProject) -> Bool {
        runningActions[canonical(project.path), default: []].contains(command)
    }

    func run(_ command: ProjectFlutterCommand, for project: FlutterProject) {
        let path = canonical(project.path)
        runningActions[path, default: []].insert(command)
        error = nil
        let operationID = UUID()
        let task = Task { [weak self, actions, activity] in
            do { try await actions.execute(command, project: project, operationID: operationID, activity: activity) }
            catch is CancellationError { }
            catch { self?.error = error.localizedDescription }
            self?.runningActions[path]?.remove(command)
            if self?.runningActions[path]?.isEmpty == true { self?.runningActions.removeValue(forKey: path) }
            self?.tasks.removeValue(forKey: operationID)
        }
        tasks[operationID] = task
    }

    func cancel(_ entry: ActivityEntry) { tasks[entry.id]?.cancel() }

    func cancelAll(for project: FlutterProject) {
        let path = canonical(project.path)
        for entry in activity.entries where entry.projectPath == path && entry.operationStatus == .running {
            tasks[entry.id]?.cancel()
        }
    }

    func clearCompleted(for project: FlutterProject) { activity.clearCompleted(projectPath: canonical(project.path)) }

    func open(_ target: ProjectIDE, for project: FlutterProject) async {
        error = nil
        do { try await ideOpening.open(target, project: project) }
        catch { self.error = error.localizedDescription }
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
