import Foundation
import Observation

enum DependencySetupState: String, Sendable {
    case checking = "Checking Dependencies"
    case ready = "Ready"
    case missingHomebrew = "Homebrew Not Found"
    case missingFVM = "FVM Not Found"
    case installing = "Installing FVM"
    case failed = "Setup Failed"
}
@MainActor @Observable final class DependencySetupViewModel {
    private(set) var state: DependencySetupState = .checking
    private(set) var homebrew: HomebrewInstallation?
    private(set) var installation: FVMInstallation?
    private(set) var detail: String?
    private(set) var output = ""
    private(set) var isWorking = false
    private(set) var cancelling = false
    private let service: any DependencySettingUp
    private let activity: ActivityStore
    private var installTask: Task<DependencyStatus, Error>?
    init(service: any DependencySettingUp, activity: ActivityStore) {
        self.service = service
        self.activity = activity
    }
    func check(fvmPath: String?, brewPath: String?) async -> FVMInstallation? {
        guard !isWorking else { return nil }
        isWorking = true
        state = .checking
        detail = nil
        defer { isWorking = false }
        do {
            let result = try await service.check(fvmPath: fvmPath, brewPath: brewPath)
            apply(result)
            return result.fvm
        } catch {
            installation = nil
            homebrew = nil
            detail = error is CancellationError ? "Dependency check cancelled. Retry when ready." : error.localizedDescription
            state = .failed
            return nil
        }
    }
    func install(fvmPath: String?, brewPath: String?) async -> FVMInstallation? {
        guard !isWorking, installation == nil, let brew = homebrew else { return nil }
        isWorking = true
        cancelling = false
        state = .installing
        detail = nil
        output = ""
        let id = activity.begin(command: "\(brew.executable.path) install fvm")
        let task = Task { [service, activity, weak self] in
            try await service.installFVM(using: brew) { [weak self] event in
                let text = (event.isError ? "[stderr] " : "") + event.text
                await self?.append(text)
                await activity.append(text, id: id)
            }
            try Task.checkCancellation()
            return try await service.check(fvmPath: fvmPath, brewPath: brewPath)
        }
        installTask = task
        defer { installTask = nil; isWorking = false; cancelling = false }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard result.fvm != nil else { throw FVMError.message("Homebrew finished, but FVM could not be verified. Check the output, select an existing FVM executable, or retry detection.\n\(result.detail ?? "")") }
            apply(result)
            activity.finish(id, status: .completed)
            return result.fvm
        } catch {
            let cancelled = error is CancellationError
            state = .failed
            detail = cancelled ? "Installation cancelled. Homebrew may have left partial files. Check dependencies before retrying." : error.localizedDescription
            append("\n" + (detail ?? ""))
            activity.append(detail ?? "", id: id)
            activity.finish(id, status: cancelled ? .cancelled : .failed)
            return nil
        }
    }
    func cancel() {
        guard installTask != nil, !cancelling else { return }
        cancelling = true
        installTask?.cancel()
    }
    private func apply(_ result: DependencyStatus) {
        installation = result.fvm
        homebrew = result.homebrew
        detail = result.detail
        state = result.fvm != nil ? .ready : result.homebrew != nil ? .missingFVM : .missingHomebrew
    }
    private func append(_ text: String) {
        output = String((output + text).suffix(200_000))
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
