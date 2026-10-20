import XCTest
@testable import fvm_gui

private struct FailingExecutor: CLIExecuting {
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        throw CLIError.launchFailed(executable, reason: "fixture failure")
    }
}

final class InfrastructureTests: XCTestCase {
    func testMissingExecutableAndLaunchFailureAreTyped() async throws {
        do {
            _ = try await CLIExecutor().run(executable: URL(fileURLWithPath: "/missing/fvm-test"), arguments: [])
            XCTFail("Expected missing executable")
        } catch CLIError.executableUnavailable(let url) {
            XCTAssertEqual(url.path, "/missing/fvm-test")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("invalid executable")
        try Data("#!/missing/interpreter\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        do {
            _ = try await CLIExecutor().run(executable: executable, arguments: [])
            XCTFail("Expected launch failure")
        } catch CLIError.launchFailed(let url, let reason) {
            XCTAssertEqual(url, executable)
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testEnvironmentAndPATHOverridesDoNotMutateParent() async throws {
        let original = ProcessInfo.processInfo.environment["FVM_GUI_TEST"]
        let executor = CLIExecutor(environment: ["PATH": "/custom/bin"], overrides: ["FVM_GUI_TEST": "literal value $()", "PATH": "/test path/bin"])
        let result = try await executor.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("FVM_GUI_TEST=literal value $()\n"))
        XCTAssertTrue(result.stdout.contains("PATH=/test path/bin\n"))
        XCTAssertTrue(result.stdout.contains("NO_COLOR=1\n"))
        XCTAssertEqual(ProcessInfo.processInfo.environment["FVM_GUI_TEST"], original)
        let paths = (CLIExecutor.environment(["PATH": "/custom/bin:/usr/bin"])["PATH"] ?? "").split(separator: ":")
        XCTAssertEqual(paths.first, "/custom/bin")
        XCTAssertEqual(paths.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testNonzeroExitValidationPreservesOutput() throws {
        do {
            try result("partial", code: 23, stderr: "denied").requireSuccess(command: "fixture")
            XCTFail("Expected nonzero failure")
        } catch CLIError.nonzeroExit(let command, let result) {
            XCTAssertEqual(command, "fixture")
            XCTAssertEqual(result.exitCode, 23)
            XCTAssertEqual(result.stdout, "partial")
            XCTAssertEqual(result.stderr, "denied")
        }
    }

    func testTimeoutIsTyped() async throws {
        do {
            _ = try await CLIExecutor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch CLIError.timedOut(let url, let timeout) {
            XCTAssertEqual(url.path, "/bin/sleep")
            XCTAssertEqual(timeout, .milliseconds(100))
        }
    }

    func testStreamingBothChannelsBeforeExit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("stdout-seen")
        let err = root.appendingPathComponent("stderr-seen")
        // Only exit successfully once BOTH streaming callbacks have acknowledged output.
        let script = "printf ready; printf warning >&2; for i in {1..100}; do if [[ -f $1 && -f $2 ]]; then exit 0; fi; sleep 0.02; done; exit 9"
        let response = try await CLIExecutor().run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", script, "fixture", out.path, err.path], timeout: .seconds(5), output: { event in
            _ = FileManager.default.createFile(atPath: (event.isError ? err : out).path, contents: Data())
        })
        XCTAssertEqual(response.exitCode, 0, "Callbacks must stream before process termination")
        XCTAssertEqual(response.stdout, "ready")
        XCTAssertEqual(response.stderr, "warning")
    }

    func testConcurrentCommandsAndCancellationAreIndependent() async throws {
        let executor = CLIExecutor()
        let collector = OutputCollector()
        let slow = Task {
            try await executor.run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", "printf started; exec /bin/sleep 30"], timeout: nil, output: { await collector.append($0) })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await collector.text.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await collector.text
        XCTAssertEqual(started, "started")
        // This must complete while the first command is still running on the SAME executor.
        let fast = try await executor.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["independent"], timeout: .seconds(2))
        slow.cancel()
        do { _ = try await slow.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fast.stdout, "independent")
        XCTAssertEqual(fast.exitCode, 0)
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CLIExecutor().run(executable: URL(fileURLWithPath: "/missing/should-not-launch"), arguments: [])
        }
        do { _ = try await task.value; XCTFail("Expected cancellation before validation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testErrorPropagatesThroughLoggingAndService() async throws {
        let activity = ActivityStore()
        let executor = LoggingCLIExecutor(base: FailingExecutor(), activity: activity)
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fixture"), version: "4"), executor: executor)
        do { _ = try await service.releases(); XCTFail("Expected launch failure") }
        catch CLIError.launchFailed(_, let reason) { XCTAssertEqual(reason, "fixture failure") }
        XCTAssertEqual(activity.entries.first?.operationStatus, .failed)
        XCTAssertTrue(activity.entries.first?.output.contains("fixture failure") == true)
    }

    @MainActor func testOperationProgressCompletionFailureAndRestart() async {
        let operation = LongRunningOperation()
        XCTAssertEqual(operation.status, .idle)
        XCTAssertTrue(operation.start { report in await report(OperationProgress(message: "Measured", fraction: 0.5)) })
        XCTAssertFalse(operation.start { _ in XCTFail("Must reject overlapping action") })
        await operation.wait()
        XCTAssertEqual(operation.status, .completed)
        XCTAssertEqual(operation.progress, OperationProgress(message: "Measured", fraction: 0.5))
        XCTAssertTrue(operation.start { _ in throw CLIError.executableUnavailable(URL(fileURLWithPath: "/fixture")) })
        await operation.wait()
        XCTAssertEqual(operation.status, .failed)
        XCTAssertTrue(operation.failure is CLIError)
        XCTAssertTrue(operation.start { _ in })
        await operation.wait()
        XCTAssertEqual(operation.status, .completed)
        XCTAssertNil(operation.failure)
    }

    @MainActor func testOperationCancellationWaitsForCleanup() async {
        let operation = LongRunningOperation()
        operation.start { _ in try await Task.sleep(for: .seconds(30)) }
        operation.cancel()
        XCTAssertEqual(operation.status, .running)
        XCTAssertTrue(operation.cancelling)
        XCTAssertFalse(operation.start { _ in })
        await operation.wait()
        XCTAssertEqual(operation.status, .cancelled)
        XCTAssertFalse(operation.cancelling)
    }

    @MainActor func testImmediateSDKCancellationReleasesUIAndServiceLocks() async throws {
        let suite = "FVM GUI tests \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executor = MockExecutor([result(#"{"versions":[]}"#), result(#"{"context":{"globalCacheLink":"/tmp/default"}}"#)])
        let app = AppContainer(defaults: defaults, executor: executor, locator: MockLocator())
        await app.detect()
        app.modify(["install", "fixture"])
        app.cancel()
        await app.operation.wait()
        XCTAssertFalse(app.busy)
        XCTAssertEqual(app.operation.status, .cancelled)
        XCTAssertTrue(app.activity.entries.contains { $0.operationStatus == .cancelled })
    }

    func testFileSystemRoundTripAndErrorPropagation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalFileSystem()
        let folder = root.appendingPathComponent("nested directory")
        let file = folder.appendingPathComponent("fixture")
        try await fileSystem.createDirectory(folder)
        try await fileSystem.write(Data("fixture".utf8), to: file)
        let directory = await fileSystem.isDirectory(folder)
        let data = try await fileSystem.read(file)
        XCTAssertTrue(directory)
        XCTAssertEqual(data, Data("fixture".utf8))
        try await fileSystem.remove(file)
        let exists = await fileSystem.exists(file)
        XCTAssertFalse(exists)
        do { _ = try await fileSystem.read(file); XCTFail("Expected missing file") }
        catch { XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain) }
    }
}
