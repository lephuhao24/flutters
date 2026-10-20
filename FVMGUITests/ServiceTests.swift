import XCTest
@testable import fvm_gui

final class ServiceTests: XCTestCase {
    func testExecutableWithSpacesAndReducedPATH() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fvm")
        try Data("fake".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let mock = MockExecutor([result("4.3.1"), result("releases project")])
        let found = try await ExecutableLocator(executor: mock, searchPath: root.path).locate(manualPath: nil)
        XCTAssertEqual(found.executable, executable)
        let calls = await mock.calls
        XCTAssertEqual(calls.map(\.arguments), [["--version"], ["api", "--help"]])
    }
    func testInvalidManualPathDoesNotFallBack() async throws {
        let mock = MockExecutor([])
        do { _ = try await ExecutableLocator(executor: mock).locate(manualPath: "/missing/fvm"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("FVM")) }
        let calls = await mock.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testProjectArgumentIsArrayAndKeepsWorkingDirectory() async throws {
        let mock = MockExecutor([result(#"{"project":{"name":"demo","isFlutter":true}}"#)])
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fake"), version: "4.3.1"), executor: mock)
        _ = try await service.project(at: URL(fileURLWithPath: "/tmp/project with spaces"))
        let calls = await mock.calls
        XCTAssertEqual(calls.first?.arguments, ["api", "project", "--path", "/tmp/project with spaces"])
    }
    func testDoctorUsesSelectedSDKExecutableVerboseFlagAndOptionalProjectDirectory() async throws {
        let sdk = FlutterSDK(name: "3.24.1", type: "release", directory: "/custom FVM cache/versions/3.24.1", flutterSdkVersion: "3.24.1", isSetup: true)
        let project = URL(fileURLWithPath: "/tmp/project with spaces", isDirectory: true)
        let executor = MockExecutor([result("[✓] Flutter\n")])
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fvm/fvm"), version: "4.3.1"), executor: executor)

        _ = try await service.runFlutterDoctor(sdk: sdk, directory: project, timeout: .seconds(120), output: nil)

        let calls = await executor.calls
        let invocation = try XCTUnwrap(calls.first)
        XCTAssertEqual(invocation.executable.path, "/custom FVM cache/versions/3.24.1/bin/flutter")
        XCTAssertEqual(invocation.arguments, ["doctor", "--verbose"])
        XCTAssertEqual(invocation.directory, project)
        XCTAssertEqual(invocation.timeout, .seconds(120))
    }
    func testNonzeroAndZeroExitInvalidJSON() async throws {
        for response in [result("failure", code: 1, stderr: "network unavailable"), result("✗ Failed to retrieve releases")] {
            let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fake"), version: "4"), executor: MockExecutor([response]))
            do { _ = try await service.releases(); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testModificationRequiresObservedPostcondition() async throws {
        let mock = MockExecutor([result("Skipped"), result(#"{"versions":[]}"#), result(#"{"context":{"globalCacheLink":"/tmp/default"}}"#)])
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fake"), version: "4"), executor: mock)
        do { try await service.modify(["install", "3.47.2"], directory: nil, output: nil); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("without installing")) }
    }
    func testSDKRemovalErrorPropagatesFromFVMCLI() async throws {
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fake"), version: "4.3.1"),
                                    executor: MockExecutor([result("SDK is in use", code: 1, stderr: "referenced by a project")]))
        do {
            try await service.modify(["remove", "3.47.2"], directory: nil, output: nil)
            XCTFail("Expected FVM removal to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("referenced by a project"))
        }
    }
    func testGlobalSymlinkUsesCanonicalPaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = root.appendingPathComponent("versions/3.47.2", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("default")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sdk)
        let list = String(decoding: try JSONSerialization.data(withJSONObject: ["versions": [["name": "3.47.2", "directory": sdk.path, "isSetup": true]]]), as: UTF8.self)
        let context = String(decoding: try JSONSerialization.data(withJSONObject: ["context": ["globalCacheLink": link.path]]), as: UTF8.self)
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fake"), version: "4.3.1"), executor: MockExecutor([result(list), result(context)]))
        let sdks = try await service.installed()
        XCTAssertEqual(sdks.first?.isGlobal, true)
    }
    @MainActor func testSDKViewModelStateTransitions() async {
        let service = MockFVM()
        let model = SDKViewModel(service: service)
        await model.refresh()
        XCTAssertEqual(model.sdks.count, 1)
        XCTAssertFalse(model.loading)
        await service.setFailure(true)
        await model.refresh()
        XCTAssertEqual(model.error, "offline")
        XCTAssertEqual(model.sdks.count, 1)
        XCTAssertFalse(model.loading)
        await service.setFailure(false)
        await model.refresh()
        XCTAssertNil(model.error)
    }
    func testProjectMissingMalformedAndInheritedConfiguration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let service = ProjectService(), fvm = MockFVM()
        do { _ = try await service.inspect(child, fvm: fvm); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("pubspec")) }
        try Data("name: example\ndependencies:\n  flutter:\n    sdk: flutter\n".utf8).write(to: child.appendingPathComponent("pubspec.yaml"))
        let missing = try await service.inspect(child, fvm: fvm)
        XCTAssertNil(missing.configurationSource)
        let config = root.appendingPathComponent(".fvmrc")
        try Data(#"{"flutter":"3.47.2"}"#.utf8).write(to: config)
        let inherited = try await service.inspect(child, fvm: fvm)
        XCTAssertEqual(inherited.configurationSource, config.path)
        try Data("bad json".utf8).write(to: child.appendingPathComponent(".fvmrc"))
        do { _ = try await service.inspect(child, fvm: fvm); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Malformed")) }
    }
}
