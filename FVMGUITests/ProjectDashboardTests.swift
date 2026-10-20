import XCTest
@testable import fvm_gui

final class ProjectDashboardTests: XCTestCase {
    func testFVMRunsTypedFlutterCommandInProjectDirectoryWithFVMExecutable() async throws {
        let executable = URL(fileURLWithPath: "/Applications/FVM CLI/fvm")
        let workingDirectory = URL(fileURLWithPath: "/tmp/Flutter projects/example app", isDirectory: true)
        let executor = MockExecutor([result("Resolving dependencies…"), result("cleaned"), result("outdated")])
        let service = FVMCLIService(installation: FVMInstallation(executable: executable, version: "4.3.1"), executor: executor)

        for command in ProjectFlutterCommand.allCases {
            let response = try await service.runFlutter(command, directory: workingDirectory, output: nil)
            XCTAssertEqual(response.exitCode, 0)
        }
        let calls = await executor.calls
        XCTAssertEqual(calls.map(\.executable), Array(repeating: executable, count: 3))
        XCTAssertEqual(calls.map(\.arguments), [["flutter", "pub", "get"], ["flutter", "clean"], ["flutter", "pub", "outdated"]])
        XCTAssertEqual(calls.map(\.directory), Array(repeating: workingDirectory, count: 3))
    }

    @MainActor func testActionStreamsOutputAndRecordsExitCodeDurationAndProjectPath() async throws {
        let activity = ActivityStore()
        let service = ProjectQuickActionService(fvm: ScriptedProjectFVM(result: result("Packages resolved")))
        let project = sampleProject()
        let id = UUID()

        try await service.execute(.pubGet, project: project, operationID: id, activity: activity)

        let entry = try XCTUnwrap(activity.entries.first { $0.id == id })
        XCTAssertEqual(entry.output, "Packages resolved")
        XCTAssertEqual(entry.operationStatus, .completed)
        XCTAssertEqual(entry.exitCode, 0)
        XCTAssertNotNil(entry.duration)
        XCTAssertEqual(entry.projectPath, URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path)
    }

    @MainActor func testNonzeroCLIExitIsRecordedAndPropagated() async throws {
        let activity = ActivityStore()
        let service = ProjectQuickActionService(fvm: ScriptedProjectFVM(result: result("details", code: 7, stderr: "pub failed")))
        let id = UUID()

        do {
            try await service.execute(.pubOutdated, project: sampleProject(), operationID: id, activity: activity)
            XCTFail("Expected nonzero exit to propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("7"))
        }
        let entry = try XCTUnwrap(activity.entries.first { $0.id == id })
        XCTAssertEqual(entry.operationStatus, .failed)
        XCTAssertEqual(entry.exitCode, 7)
        XCTAssertTrue(entry.output.contains("[stderr] pub failed"))
    }

    @MainActor func testCancellationAndConflictingOperationsAreHandledWhileDoctorCanRunIndependently() async throws {
        let activity = ActivityStore()
        let fvm = ScriptedProjectFVM(result: result("running"), delay: .milliseconds(160))
        let service = ProjectQuickActionService(fvm: fvm)
        let project = sampleProject()
        let firstID = UUID()
        let first = Task { try await service.execute(.clean, project: project, operationID: firstID, activity: activity) }

        for _ in 0..<100 where !activity.entries.contains(where: { $0.id == firstID }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        do {
            try await service.execute(.pubGet, project: project, operationID: UUID(), activity: activity)
            XCTFail("Pub get must not overlap with an active package action")
        } catch { XCTAssertTrue(error.localizedDescription.contains("conflicting")) }

        try await service.execute(.pubOutdated, project: project, operationID: UUID(), activity: activity)
        try await first.value
        let maximumConcurrentRuns = await fvm.maximumConcurrentRuns
        XCTAssertEqual(maximumConcurrentRuns, 2, "Independent project actions should not be unnecessarily serialized")

        let cancelledFVM = ScriptedProjectFVM(result: result("waiting"), delay: .seconds(5))
        let cancelledService = ProjectQuickActionService(fvm: cancelledFVM)
        let cancelledID = UUID()
        let cancelledTask = Task { try await cancelledService.execute(.clean, project: project, operationID: cancelledID, activity: activity) }
        for _ in 0..<100 where !activity.entries.contains(where: { $0.id == cancelledID }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        cancelledTask.cancel()
        do { try await cancelledTask.value; XCTFail("Expected cancelled operation") }
        catch is CancellationError { }
        let cancelledEntry = try XCTUnwrap(activity.entries.first { $0.id == cancelledID })
        XCTAssertEqual(cancelledEntry.operationStatus, .cancelled)
    }

    @MainActor func testIDEAvailabilityPreferencesAndMissingIOSWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = sampleProject(path: root.path)
        let app = root.appendingPathComponent("Custom VS Code.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectIDEPreferences-\(UUID())"))
        let preferences = ProjectIDEPreferences(defaults: defaults)
        preferences.setApplication(app, for: .visualStudioCode)
        let resolver = MockIDEResolver(available: [.visualStudioCode: app, .xcode: root])
        let service = ProjectIDEOpeningService(preferences: preferences, resolver: resolver)

        XCTAssertTrue(service.isAvailable(.visualStudioCode))
        XCTAssertEqual(preferences.path(for: .visualStudioCode), app.path)
        XCTAssertFalse(service.isAvailable(.androidStudio))
        do {
            try await service.open(.xcode, project: project)
            XCTFail("Missing iOS workspace should be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains(".xcworkspace")) }
        do {
            try await service.open(.androidStudio, project: project)
            XCTFail("Missing IDE should be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Android Studio")) }
    }

    @MainActor func testIOSWorkspacePrefersRunnerWorkspaceAndIDEOpenUsesConfiguredApplication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ios = root.appendingPathComponent("ios", isDirectory: true)
        let runner = ios.appendingPathComponent("Runner.xcworkspace", isDirectory: true)
        let other = ios.appendingPathComponent("Other.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let locatedWorkspace = try XCTUnwrap(ProjectIDEOpeningService.iOSWorkspace(in: root))
        XCTAssertEqual(locatedWorkspace.lastPathComponent, "Runner.xcworkspace")
        XCTAssertEqual(locatedWorkspace.deletingLastPathComponent().lastPathComponent, "ios")

        let xcode = root.appendingPathComponent("Custom Xcode.app")
        try FileManager.default.createDirectory(at: xcode, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectIDEPreferences-\(UUID())"))
        let preferences = ProjectIDEPreferences(defaults: defaults)
        preferences.setApplication(xcode, for: .xcode)
        let resolver = MockIDEResolver(available: [:])
        let service = ProjectIDEOpeningService(preferences: preferences, resolver: resolver)
        try await service.open(.xcode, project: sampleProject(path: root.path))
        XCTAssertEqual(resolver.openedURLs.first?.lastPathComponent, runner.lastPathComponent)
        XCTAssertEqual(resolver.openedURLs.first?.deletingLastPathComponent().lastPathComponent, "ios")
        XCTAssertEqual(resolver.openedApplications.first?.lastPathComponent, xcode.lastPathComponent)
    }

    @MainActor func testActivityClearRemovesOnlyCompletedProjectEntries() async {
        let activity = ActivityStore()
        let projectPath = "/tmp/project"
        let first = activity.begin(command: "fvm flutter clean", projectPath: projectPath)
        let other = activity.begin(command: "fvm flutter doctor", projectPath: "/tmp/other")
        activity.finish(first, status: .completed, exitCode: 0, duration: .seconds(1))
        activity.clearCompleted(projectPath: projectPath)
        XCTAssertNil(activity.entries.first { $0.id == first })
        XCTAssertNotNil(activity.entries.first { $0.id == other })
    }

    private func sampleProject(path: String = "/tmp/example") -> FlutterProject {
        FlutterProject(path: path, name: "example", version: "3.24.1", type: .flutterApp)
    }
}

private actor ScriptedProjectFVM: FVMService {
    private let result: CLIResult
    private let delay: Duration
    private(set) var currentRuns = 0
    private(set) var maximumConcurrentRuns = 0

    init(result: CLIResult, delay: Duration = .zero) { self.result = result; self.delay = delay }
    func installed() async throws -> [FlutterSDK] { [] }
    func releases() async throws -> [FlutterRelease] { [] }
    func project(at url: URL) async throws -> (name: String, version: String?, isFlutter: Bool) { ("example", nil, true) }
    func modify(_ arguments: [String], directory: URL?, output: OutputHandler?) async throws { }
    func runFlutter(_ command: ProjectFlutterCommand, directory: URL, output: OutputHandler?) async throws -> CLIResult {
        currentRuns += 1
        maximumConcurrentRuns = max(maximumConcurrentRuns, currentRuns)
        defer { currentRuns -= 1 }
        await output?(CLIOutput(text: result.stdout, isError: false))
        if !result.stderr.isEmpty { await output?(CLIOutput(text: result.stderr, isError: true)) }
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return result
    }
    func runFlutterDoctor(sdk: FlutterSDK, directory: URL?, timeout: Duration, output: OutputHandler?) async throws -> CLIResult {
        currentRuns += 1
        maximumConcurrentRuns = max(maximumConcurrentRuns, currentRuns)
        defer { currentRuns -= 1 }
        await output?(CLIOutput(text: result.stdout, isError: false))
        if !result.stderr.isEmpty { await output?(CLIOutput(text: result.stderr, isError: true)) }
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        return result
    }
}

@MainActor private final class MockIDEResolver: IDEApplicationResolving {
    let available: [ProjectIDE: URL]
    private(set) var openedURLs: [URL] = []
    private(set) var openedApplications: [URL] = []
    init(available: [ProjectIDE: URL]) { self.available = available }
    func applicationURL(for ide: ProjectIDE, preferredPath: String?) -> URL? {
        if let preferredPath, FileManager.default.fileExists(atPath: preferredPath) { return URL(fileURLWithPath: preferredPath) }
        return available[ide]
    }
    func open(_ urls: [URL], with applicationURL: URL) async throws {
        openedURLs = urls
        openedApplications.append(applicationURL)
    }
}
