import Foundation

protocol ExecutableLocating: Sendable {
    func locate(manualPath: String?) async throws -> FVMInstallation
}
struct ExecutableLocator: ExecutableLocating {
    let executor: any CLIExecuting
    var searchPath: String = CLIExecutor.environment()["PATH"] ?? ""
    func locate(manualPath: String?) async throws -> FVMInstallation {
        let candidates: [String]
        if let manualPath, !manualPath.isEmpty { candidates = [manualPath] }
        else { candidates = searchPath.components(separatedBy: ":").filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).appendingPathComponent("fvm").path } }
        var failure = "FVM was not found. Install FVM, or select its executable in Settings."
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            do {
                let url = URL(fileURLWithPath: path)
                let version = try await executor.run(executable: url, arguments: ["--version"], directory: nil, timeout: .seconds(10), output: nil)
                let api = try await executor.run(executable: url, arguments: ["api", "--help"], directory: nil, timeout: .seconds(10), output: nil)
                guard version.exitCode == 0, !version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, api.exitCode == 0, api.stdout.contains("releases"), api.stdout.contains("project") else { throw FVMError.message("This executable does not support the required FVM JSON API. Use FVM 4.3.1 or a compatible release.") }
                return FVMInstallation(executable: url, version: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error.localizedDescription }
        }
        throw FVMError.message(failure)
    }
}
