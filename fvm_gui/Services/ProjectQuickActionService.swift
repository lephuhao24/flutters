import Foundation

enum ProjectActionError: LocalizedError, Sendable {
    case fvmUnavailable
    case conflictingOperation(String)

    var errorDescription: String? {
        switch self {
        case .fvmUnavailable: "FVM is unavailable. Configure FVM before running project actions."
        case .conflictingOperation(let action): "A conflicting project operation is already running. Wait for \(action) to finish."
        }
    }
}

/// Coordinates project CLI actions and streams their output into the shared activity history.
/// Package resolution is serialized per canonical project path; independent clean/outdated
/// operations may proceed concurrently. Flutter Doctor is coordinated by FlutterDoctorService.
actor ProjectQuickActionService {
    private var fvm: (any FVMService)?
    private var activeByProject: [String: Set<ProjectFlutterCommand>] = [:]
    private let clock = ContinuousClock()

    init(fvm: (any FVMService)? = nil) { self.fvm = fvm }

    func configure(fvm: (any FVMService)?) { self.fvm = fvm }

    func execute(_ command: ProjectFlutterCommand, project: FlutterProject, operationID: UUID,
                 activity: ActivityStore) async throws {
        guard let fvm else { throw ProjectActionError.fvmUnavailable }
        let projectPath = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path
        let active = activeByProject[projectPath, default: []]
        if active.contains(command) || active.contains(.pubGet) || (command == .pubGet && !active.isEmpty) {
            let activeName = active.map(\.title).sorted().joined(separator: ", ")
            throw ProjectActionError.conflictingOperation(activeName.isEmpty ? command.title : activeName)
        }
        activeByProject[projectPath, default: []].insert(command)
        defer {
            activeByProject[projectPath]?.remove(command)
            if activeByProject[projectPath]?.isEmpty == true { activeByProject.removeValue(forKey: projectPath) }
        }

        let entryID = await activity.begin(command: "fvm flutter \(command.arguments.joined(separator: " "))",
                                           projectPath: projectPath, id: operationID)
        let started = clock.now
        var exitCode: Int32?
        do {
            try Task.checkCancellation()
            let result = try await fvm.runFlutter(command, directory: URL(fileURLWithPath: projectPath), output: { event in
                await activity.append((event.isError ? "[stderr] " : "") + event.text, id: entryID)
            })
            let elapsed = started.duration(to: clock.now)
            exitCode = result.exitCode
            let status: OperationStatus = result.exitCode == 0 ? .completed : .failed
            await activity.finish(entryID, status: status, exitCode: result.exitCode, duration: elapsed)
            guard result.exitCode == 0 else {
                throw CLIError.nonzeroExit(command: "fvm flutter \(command.arguments.joined(separator: " "))", result: result)
            }
        } catch is CancellationError {
            await activity.finish(entryID, status: .cancelled, duration: started.duration(to: clock.now))
            throw CancellationError()
        } catch {
            if exitCode == nil { await activity.append(error.localizedDescription + "\n", id: entryID) }
            await activity.finish(entryID, status: .failed, exitCode: exitCode, duration: started.duration(to: clock.now))
            throw error
        }
    }
}
