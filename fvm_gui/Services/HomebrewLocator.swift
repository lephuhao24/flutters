import Foundation

struct HomebrewInstallation: Sendable, Equatable {
    let executable: URL
    let version: String
    let prefix: URL
}
protocol HomebrewLocating: Sendable {
    func locate(manualPath: String?) async throws -> HomebrewInstallation
}
actor HomebrewLocator: HomebrewLocating {
    private let executor: any CLIExecuting
    private let searchPath: String
    private let standardPaths: [String]
    init(executor: any CLIExecuting, searchPath: String = CLIExecutor.environment()["PATH"] ?? "",
         standardPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
        self.executor = executor
        self.searchPath = searchPath
        self.standardPaths = standardPaths
    }
    func locate(manualPath: String?) async throws -> HomebrewInstallation {
        let candidates: [String]
        if let manualPath, !manualPath.isEmpty { candidates = [manualPath] }
        else {
            candidates = searchPath.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("brew").path } + standardPaths
        }
        var seen = Set<String>()
        var detail = "Homebrew was not found. Install it using the official instructions, or select an existing brew executable."
        for path in candidates where seen.insert(path).inserted {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                if manualPath?.isEmpty == false { throw FVMError.message("Homebrew is missing or not executable at \(path). Choose another executable.") }
                continue
            }
            do {
                let url = URL(fileURLWithPath: path)
                let version = try await executor.run(executable: url, arguments: ["--version"], directory: nil, timeout: .seconds(15), output: nil)
                guard version.exitCode == 0, version.stdout.hasPrefix("Homebrew ") else { throw FVMError.message("The selected executable did not return a valid Homebrew --version response. \(version.stderr)") }
                let prefix = try await executor.run(executable: url, arguments: ["--prefix"], directory: nil, timeout: .seconds(15), output: nil)
                let path = prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard prefix.exitCode == 0, path.hasPrefix("/"), !path.contains("\n") else { throw FVMError.message("Cannot read Homebrew's installation prefix. \(prefix.stderr)") }
                return HomebrewInstallation(executable: url, version: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), prefix: URL(fileURLWithPath: path, isDirectory: true))
            } catch is CancellationError { throw CancellationError() }
            catch {
                if manualPath?.isEmpty == false { throw error }
                detail = error.localizedDescription
            }
        }
        throw FVMError.message(detail)
    }
}
