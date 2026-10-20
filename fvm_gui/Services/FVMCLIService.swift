import Foundation

protocol FVMService: Sendable {
    func installed() async throws -> [FlutterSDK]
    func releases() async throws -> [FlutterRelease]
    func project(at url: URL) async throws -> (name: String, version: String?, isFlutter: Bool)
    func modify(_ arguments: [String], directory: URL?, output: OutputHandler?) async throws
    func runFlutter(_ command: ProjectFlutterCommand, directory: URL, output: OutputHandler?) async throws -> CLIResult
    func runFlutterDoctor(sdk: FlutterSDK, directory: URL?, timeout: Duration, output: OutputHandler?) async throws -> CLIResult
}

/// Closed set of project-scoped Flutter commands exposed by the dashboard.
/// Keeping arguments typed prevents arbitrary CLI injection and guarantees FVM's project resolution.
enum ProjectFlutterCommand: String, Sendable, CaseIterable, Identifiable {
    case pubGet
    case clean
    case pubOutdated

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pubGet: "Pub Get"
        case .clean: "Flutter Clean"
        case .pubOutdated: "Pub Outdated"
        }
    }
    var arguments: [String] {
        switch self {
        case .pubGet: ["pub", "get"]
        case .clean: ["clean"]
        case .pubOutdated: ["pub", "outdated"]
        }
    }
}
actor FVMCLIService: FVMService {
    let installation: FVMInstallation
    let executor: any CLIExecuting
    let parser = FVMParser()
    private var modifying = false
    private var activeFlutterRuns = 0
    init(installation: FVMInstallation, executor: any CLIExecuting) {
        self.installation = installation
        self.executor = executor
    }
    private func query(_ arguments: [String]) async throws -> String {
        let result = try await executor.run(executable: installation.executable, arguments: arguments, directory: nil, timeout: .seconds(45), output: nil)
        let checked = CLIResult(exitCode: result.exitCode, stdout: arguments == ["api", "context"] ? "" : result.stdout, stderr: result.stderr)
        try checked.requireSuccess(command: "FVM")
        return result.stdout
    }
    func installed() async throws -> [FlutterSDK] {
        var items = try parser.sdks(await query(["api", "list"]))
        let link = try parser.globalLink(await query(["api", "context"]))
        let target = link.resolvingSymlinksInPath().standardizedFileURL.path
        for index in items.indices { items[index].isGlobal = URL(fileURLWithPath: items[index].directory).resolvingSymlinksInPath().standardizedFileURL.path == target }
        return items
    }
    func releases() async throws -> [FlutterRelease] { try parser.releases(await query(["api", "releases"])) }
    func project(at url: URL) async throws -> (name: String, version: String?, isFlutter: Bool) {
        try parser.project(await query(["api", "project", "--path", url.path]))
    }
    func modify(_ arguments: [String], directory: URL?, output: OutputHandler?) async throws {
        guard !modifying, activeFlutterRuns == 0 else { throw FVMError.message("Another SDK operation is running. Wait for it to finish before starting a project command.") }
        guard let command = arguments.first, ["install", "remove", "global", "use"].contains(command), arguments.count >= 2,
              !arguments[1].hasPrefix("-"), !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FVMError.message("Enter a valid Flutter version.") }
        modifying = true
        defer { modifying = false }
        let result = try await executor.run(executable: installation.executable, arguments: arguments, directory: directory, timeout: nil, output: output)
        try result.requireSuccess(command: "FVM")
        let sdks = try await installed()
        let version = arguments[1]
        let sdk = sdks.first { $0.name == version }
        switch command {
        case "install":
            guard let sdk else { throw FVMError.message("FVM exited without installing \(version). Review Activity and retry.") }
            guard arguments.contains("--no-setup") || sdk.isSetup else { throw FVMError.message("SDK files exist, but setup is incomplete. Review Activity and retry installation.") }
        case "remove": guard sdk == nil else { throw FVMError.message("FVM did not remove \(version). It may still be in use. Review Activity.") }
        case "global": guard sdk?.isGlobal == true else { throw FVMError.message("FVM did not change the global SDK. Review Activity.") }
        case "use":
            guard let directory, try await project(at: directory).version == version else { throw FVMError.message("Project version did not change. Review Activity.") }
        default: break
        }
    }

    func runFlutter(_ command: ProjectFlutterCommand, directory: URL, output: OutputHandler?) async throws -> CLIResult {
        // `fvm flutter` resolves the SDK from this project's .fvmrc/.fvm configuration.
        // Never invoke a global `flutter` executable from a project dashboard action.
        guard !modifying else { throw FVMError.message("An FVM SDK operation is running. Wait for it to finish.") }
        activeFlutterRuns += 1
        defer { activeFlutterRuns -= 1 }
        return try await executor.run(executable: installation.executable,
                                      arguments: ["flutter"] + command.arguments,
                                      directory: directory,
                                      timeout: nil,
                                      output: output)
    }

    func runFlutterDoctor(sdk: FlutterSDK, directory: URL?, timeout: Duration, output: OutputHandler?) async throws -> CLIResult {
        guard !modifying else { throw FVMError.message("An FVM SDK operation is running. Wait for it to finish.") }
        guard sdk.isSetup else { throw FVMError.message("Flutter SDK \(sdk.name) setup is incomplete.") }
        let executable = URL(fileURLWithPath: sdk.directory, isDirectory: true).appendingPathComponent("bin/flutter")
        activeFlutterRuns += 1
        defer { activeFlutterRuns -= 1 }
        // Flutter officially supports --verbose; no JSON output option is assumed.
        return try await executor.run(executable: executable, arguments: ["doctor", "--verbose"],
                                      directory: directory, timeout: timeout, output: output)
    }
}
