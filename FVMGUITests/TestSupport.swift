import XCTest
@testable import fvm_gui

actor MockExecutor: CLIExecuting {
    struct Call: Sendable { let executable: URL; let arguments: [String]; let directory: URL?; let timeout: Duration? }
    var responses: [CLIResult]
    var calls: [Call] = []
    var delay: Duration?
    init(_ responses: [CLIResult], delay: Duration? = nil) { self.responses = responses; self.delay = delay }
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        calls.append(Call(executable: executable, arguments: arguments, directory: directory, timeout: timeout))
        if let delay { try await Task.sleep(for: delay) }
        guard !responses.isEmpty else { throw FVMError.message("No mock response") }
        let response = responses.removeFirst()
        await output?(CLIOutput(text: response.stdout, isError: false))
        return response
    }
}
actor MockFVM: FVMService {
    var fail = false
    func setFailure(_ fail: Bool) { self.fail = fail }
    func installed() async throws -> [FlutterSDK] {
        if fail { throw FVMError.message("offline") }
        return [FlutterSDK(name: "3.47.2", type: "release", directory: "/tmp/sdk", flutterSdkVersion: "3.47.2", isSetup: true)]
    }
    func releases() async throws -> [FlutterRelease] { [] }
    func project(at url: URL) async throws -> (name: String, version: String?, isFlutter: Bool) { ("example", "3.47.2", true) }
    func modify(_ arguments: [String], directory: URL?, output: OutputHandler?) async throws { }
    func runFlutter(_ command: ProjectFlutterCommand, directory: URL, output: OutputHandler?) async throws -> CLIResult {
        let result = CLIResult(exitCode: 0, stdout: "completed", stderr: "")
        await output?(CLIOutput(text: result.stdout, isError: false))
        return result
    }
    func runFlutterDoctor(sdk: FlutterSDK, directory: URL?, timeout: Duration, output: OutputHandler?) async throws -> CLIResult {
        let result = CLIResult(exitCode: 0, stdout: "[✓] Flutter", stderr: "")
        await output?(CLIOutput(text: result.stdout, isError: false))
        return result
    }
}
func result(_ stdout: String, code: Int32 = 0, stderr: String = "") -> CLIResult { CLIResult(exitCode: code, stdout: stdout, stderr: stderr) }
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FVM GUI tests \(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func fixture(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
}
