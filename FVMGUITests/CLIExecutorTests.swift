import XCTest
import Darwin
@testable import fvm_gui

actor OutputCollector {
    var text = ""
    func append(_ event: CLIOutput) { text += event.text }
}
final class CLIExecutorTests: XCTestCase {
    func testConcurrentPipesAndExitCode() async throws {
        let script = "for i in {1..12000}; do echo stdout-$i; echo stderr-$i >&2; done; exit 7"
        let result = try await CLIExecutor().run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", script], timeout: .seconds(15))
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.stdout.contains("stdout-12000"))
        XCTAssertTrue(result.stderr.contains("stderr-12000"))
    }
    func testExecutableAndWorkingDirectoryWithSpacesAndLiteralArguments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("test executable")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$1\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let result = try await CLIExecutor().run(executable: executable, arguments: ["$(touch SHOULD_NOT_EXIST)"], directory: root)
        XCTAssertTrue(result.stdout.contains(root.path))
        XCTAssertTrue(result.stdout.contains("$(touch SHOULD_NOT_EXIST)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }
    func testPermissionDenied() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not executable")
        try Data().write(to: file)
        do { _ = try await CLIExecutor().run(executable: file, arguments: []); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not executable")) }
    }
    func testStreamingSplitUTF8() async throws {
        let collector = OutputCollector()
        let result = try await CLIExecutor().run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", "printf '\\342'; sleep 0.1; printf '\\202\\254\\n'; printf error >&2"], output: { await collector.append($0) })
        XCTAssertEqual(result.stdout, "€\n")
        let text = await collector.text
        XCTAssertTrue(text.contains("€"))
        XCTAssertFalse(text.contains("�"))
    }
    func testTimeoutTerminatesChildrenAndAllowsNextExecution() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let executor = CLIExecutor()
        let start = ContinuousClock.now
        do {
            _ = try await executor.run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", "sleep 30 & echo $! > \"$1\"; wait", "test", pidFile.path], timeout: .milliseconds(300))
            XCTFail("Should time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(kill(pid, 0), -1, "Child must be terminated")
        } else { XCTFail("Child did not start") }
        let result = try await executor.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        XCTAssertEqual(result.exitCode, 0)
    }
    func testExitedParentCannotLeavePipeHoldingChild() async throws {
        let start = ContinuousClock.now
        let result = try await CLIExecutor().run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", "trap '' TERM; sleep 30 & exit 0"], timeout: .seconds(2))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }
    func testCancellation() async throws {
        let task = Task { try await CLIExecutor().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
