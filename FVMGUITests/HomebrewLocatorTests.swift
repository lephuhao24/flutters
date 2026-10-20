import XCTest
@testable import fvm_gui

final class HomebrewLocatorTests: XCTestCase {
    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mock".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func testAppleSiliconAndIntelCandidatesWithEmptyPATH() async throws {
        for suffix in ["opt/homebrew", "usr/local"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("\(suffix)/bin/brew")
            try makeExecutable(executable)
            let prefix = root.appendingPathComponent(suffix).path
            let executor = MockExecutor([result("Homebrew 4.6.0\n"), result(prefix + "\n")])
            let locator = HomebrewLocator(executor: executor, searchPath: "", standardPaths: [root.appendingPathComponent("opt/homebrew/bin/brew").path, root.appendingPathComponent("usr/local/bin/brew").path])
            let found = try await locator.locate(manualPath: nil)
            XCTAssertEqual(found.executable, executable)
            XCTAssertEqual(found.prefix.path, prefix)
            let calls = await executor.calls
            XCTAssertEqual(calls.map(\.arguments), [["--version"], ["--prefix"]])
        }
    }
    func testCustomPathWithSpacesAndPATHDiscovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("custom prefix/bin/brew")
        try makeExecutable(executable)
        for manual in [false, true] {
            let executor = MockExecutor([result("Homebrew 4.6.0"), result(root.appendingPathComponent("custom prefix").path)])
            let locator = HomebrewLocator(executor: executor, searchPath: executable.deletingLastPathComponent().path, standardPaths: [])
            let found = try await locator.locate(manualPath: manual ? executable.path : nil)
            XCTAssertEqual(found.executable, executable)
            let calls = await executor.calls
            XCTAssertTrue(calls.allSatisfy { $0.executable == executable })
        }
    }
    func testInvalidOrNonExecutableManualPathDoesNotFallBack() async throws {
        let executor = MockExecutor([])
        let locator = HomebrewLocator(executor: executor)
        do { _ = try await locator.locate(manualPath: "/missing/brew"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not executable")) }
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testInvalidVersionNonzeroAndPrefixAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("brew")
        try makeExecutable(executable)
        for responses in [[result("not Homebrew")], [result("", code: 1, stderr: "Permission denied")], [result("Homebrew 4.6.0"), result("relative/prefix")]] {
            let locator = HomebrewLocator(executor: MockExecutor(responses), searchPath: "", standardPaths: [])
            do { _ = try await locator.locate(manualPath: executable.path); XCTFail() }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testDartPubFVMUsesExistingLocatorAndVersionValidation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".pub-cache/bin/fvm")
        try makeExecutable(executable)
        let executor = MockExecutor([result("4.3.1"), result("releases project")])
        let found = try await ExecutableLocator(executor: executor, searchPath: executable.deletingLastPathComponent().path).locate(manualPath: nil)
        XCTAssertEqual(found.executable, executable)
        let calls = await executor.calls
        XCTAssertEqual(calls.first?.arguments, ["--version"])
    }
}
