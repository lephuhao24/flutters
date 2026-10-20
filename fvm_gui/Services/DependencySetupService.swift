import Foundation

struct DependencyStatus: Sendable {
    let fvm: FVMInstallation?
    let homebrew: HomebrewInstallation?
    let detail: String?
}
protocol DependencySettingUp: Sendable {
    func check(fvmPath: String?, brewPath: String?) async throws -> DependencyStatus
    func installFVM(using brew: HomebrewInstallation, output: OutputHandler?) async throws
}
actor DependencySetupService: DependencySettingUp {
    private let fvmLocator: any ExecutableLocating
    private let brewLocator: any HomebrewLocating
    private let executor: any CLIExecuting
    private var installing = false
    init(fvmLocator: any ExecutableLocating, brewLocator: any HomebrewLocating, executor: any CLIExecuting) {
        self.fvmLocator = fvmLocator
        self.brewLocator = brewLocator
        self.executor = executor
    }
    func check(fvmPath: String?, brewPath: String?) async throws -> DependencyStatus {
        guard !installing else { throw FVMError.message("FVM installation is still running. Wait for cleanup to finish.") }
        let fvmFailure: String
        do {
            let fvm = try await fvmLocator.locate(manualPath: fvmPath)
            return DependencyStatus(fvm: fvm, homebrew: nil, detail: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // An explicit invalid override needs correction, not another installation.
            if fvmPath?.isEmpty == false { throw error }
            fvmFailure = error.localizedDescription
        }
        let brew: HomebrewInstallation
        do { brew = try await brewLocator.locate(manualPath: brewPath) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if brewPath?.isEmpty == false { throw error }
            return DependencyStatus(fvm: nil, homebrew: nil, detail: "\(fvmFailure)\n\(error.localizedDescription)")
        }
        // A custom Homebrew prefix may be absent from the GUI application's PATH.
        do {
            let fvm = try await fvmLocator.locate(manualPath: brew.prefix.appendingPathComponent("bin/fvm").path)
            return DependencyStatus(fvm: fvm, homebrew: brew, detail: nil)
        } catch is CancellationError { throw CancellationError() }
        catch { return DependencyStatus(fvm: nil, homebrew: brew, detail: fvmFailure + "\n" + error.localizedDescription) }
    }
    func installFVM(using brew: HomebrewInstallation, output: OutputHandler?) async throws {
        guard !installing else { throw FVMError.message("Another FVM installation is already running.") }
        installing = true
        defer { installing = false }
        // Revalidate the selected executable immediately before invoking it.
        let validated = try await brewLocator.locate(manualPath: brew.executable.path)
        let result = try await executor.run(executable: validated.executable, arguments: ["install", "fvm"], directory: nil, timeout: nil, output: output)
        guard result.exitCode == 0 else {
            throw FVMError.message("Homebrew could not install FVM (exit \(result.exitCode)). Check network access and write permissions for the Homebrew prefix, then retry.\n\(result.stderr)\n\(result.stdout)")
        }
    }
}
