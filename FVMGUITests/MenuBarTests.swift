import XCTest
@testable import fvm_gui

@MainActor final class MenuBarTests: XCTestCase {
    func testMenuBarSettingsAndRecentCountPersist() throws {
        let suite = "FVM GUI menu bar \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = MenuBarPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertTrue(preferences.showRecentProjects)
        XCTAssertTrue(preferences.keepRunningWhenMainWindowCloses)
        preferences.showMenuBarIcon = false
        preferences.showRecentProjects = false
        preferences.keepRunningWhenMainWindowCloses = false
        preferences.recentProjectCount = 10

        let reopened = MenuBarPreferences(defaults: defaults)
        XCTAssertFalse(reopened.showMenuBarIcon)
        XCTAssertFalse(reopened.showRecentProjects)
        XCTAssertFalse(reopened.keepRunningWhenMainWindowCloses)
        XCTAssertEqual(reopened.recentProjectCount, 10)
        reopened.recentProjectCount = 4
        XCTAssertEqual(reopened.recentProjectCount, 5)
    }

    func testPreferredIDEPreferencePersists() throws {
        let suite = "FVM GUI preferred IDE \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProjectIDEPreferences(defaults: defaults)
        XCTAssertEqual(preferences.preferredIDE, .visualStudioCode)
        preferences.setPreferredIDE(.androidStudio)
        XCTAssertEqual(ProjectIDEPreferences(defaults: defaults).preferredIDE, .androidStudio)
        preferences.setPreferredIDE(.finder)
        XCTAssertEqual(preferences.preferredIDE, .androidStudio)
    }

    func testRecentProjectsUseAccessOrderDeduplicateAndRespectLimit() throws {
        let suite = "FVM GUI recents \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let projects = [
            FlutterProject(path: "/tmp/a", name: "A"),
            FlutterProject(path: "/tmp/b", name: "B"),
            FlutterProject(path: "/tmp/c", name: "C"),
            FlutterProject(path: "/tmp/d", name: "D")
        ]
        defaults.set(try JSONEncoder().encode(projects), forKey: "projects")
        defaults.set(["/tmp/b", "/tmp/c", "/tmp/b", "/tmp/a"], forKey: "recentProjectPaths")
        let app = AppContainer(defaults: defaults, launchAtLoginService: MockLaunchAtLogin())

        XCTAssertEqual(app.recentProjects(limit: 3).map(\.name), ["B", "C", "A"])
        app.recordRecentProject(projects[3])
        XCTAssertEqual(app.recentProjects(limit: 2).map(\.name), ["D", "B"])
        XCTAssertEqual(AppContainer(defaults: defaults, launchAtLoginService: MockLaunchAtLogin()).recentProjects(limit: 1).map(\.name), ["D"])
    }

    func testMissingRecentProjectIsDetectedWithoutScanningDirectoryTree() async throws {
        let suite = "FVM GUI missing recent \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("missing-project-\(UUID())").path
        let project = FlutterProject(path: path, name: "Deleted project")
        defaults.set(try JSONEncoder().encode([project]), forKey: "projects")
        defaults.set([path], forKey: "recentProjectPaths")
        let model = MenuBarViewModel(container: AppContainer(defaults: defaults, launchAtLoginService: MockLaunchAtLogin()))

        await model.refreshProjectAvailability()
        XCTAssertTrue(model.isMissing(project))
    }

    func testGlobalSDKSwitchSynchronizesSharedSDKStateAndRejectsDuplicateRequest() async throws {
        let executor = SwitchingCLIExecutor(delay: .milliseconds(80))
        let app = AppContainer(executor: executor, locator: MockLocator(), launchAtLoginService: MockLaunchAtLogin())
        await app.detect()
        XCTAssertEqual(app.sdkModel?.sdks.first(where: \.isGlobal)?.name, "3.47.2")

        app.setGlobalSDK("3.41.6")
        XCTAssertTrue(app.busy)
        app.setGlobalSDK("3.41.6")
        await app.operation.wait()

        let switchCount = await executor.globalSwitchCount
        XCTAssertEqual(switchCount, 1)
        XCTAssertEqual(app.sdkModel?.sdks.first(where: \.isGlobal)?.name, "3.41.6")
        XCTAssertNil(app.error)
    }

    func testGlobalSDKSwitchFailureIsSurfacedAndSharedStateStaysAccurate() async throws {
        let executor = SwitchingCLIExecutor(failGlobalSwitch: true)
        let app = AppContainer(executor: executor, locator: MockLocator(), launchAtLoginService: MockLaunchAtLogin())
        await app.detect()
        app.setGlobalSDK("3.41.6")
        await app.operation.wait()

        XCTAssertTrue(app.error?.contains("global switch failed") == true)
        XCTAssertEqual(app.sdkModel?.sdks.first(where: \.isGlobal)?.name, "3.47.2")
        XCTAssertEqual(app.activity.entries.first(where: { $0.command == "fvm global 3.41.6" })?.operationStatus, .failed)
    }

    func testLaunchAtLoginStatusAndRegistrationErrorsAreVisible() throws {
        let service = MockLaunchAtLogin()
        XCTAssertEqual(service.status, .disabled)
        try service.setEnabled(true)
        XCTAssertEqual(service.status, .enabled)
        service.status = .requiresApproval
        XCTAssertEqual(service.status.title, "Needs approval")
        service.shouldFail = true
        XCTAssertThrowsError(try service.setEnabled(false))
        XCTAssertEqual(service.errorMessage, "registration denied")
    }
}

@MainActor private final class MockLaunchAtLogin: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus = .disabled
    private(set) var errorMessage: String?
    var shouldFail = false

    func refreshStatus() { }
    func setEnabled(_ enabled: Bool) throws {
        if shouldFail {
            errorMessage = "registration denied"
            throw FVMError.message(errorMessage!)
        }
        errorMessage = nil
        status = enabled ? .enabled : .disabled
    }
}

private actor SwitchingCLIExecutor: CLIExecuting {
    private var globalSDK = "3.47.2"
    private var switchCount = 0
    private let delay: Duration?
    private let failGlobalSwitch: Bool

    init(delay: Duration? = nil, failGlobalSwitch: Bool = false) {
        self.delay = delay
        self.failGlobalSwitch = failGlobalSwitch
    }

    var globalSwitchCount: Int { switchCount }

    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        let response: CLIResult
        if arguments == ["api", "list"] {
            response = CLIResult(exitCode: 0, stdout: Self.list, stderr: "")
        } else if arguments == ["api", "context"] {
            let path = "/tmp/fvm/versions/\(globalSDK)"
            response = CLIResult(exitCode: 0, stdout: #"{"context":{"globalCacheLink":"\#(path)"}}"#, stderr: "")
        } else if arguments.first == "global", arguments.count == 2 {
            switchCount += 1
            if let delay { try await Task.sleep(for: delay) }
            if failGlobalSwitch {
                response = CLIResult(exitCode: 1, stdout: "", stderr: "global switch failed")
            } else {
                globalSDK = arguments[1]
                response = CLIResult(exitCode: 0, stdout: "global set", stderr: "")
            }
        } else {
            response = CLIResult(exitCode: 1, stdout: "", stderr: "unexpected command \(arguments)")
        }
        await output?(CLIOutput(text: response.stdout, isError: false))
        if !response.stderr.isEmpty { await output?(CLIOutput(text: response.stderr, isError: true)) }
        return response
    }

    private static let list = #"{"versions":[{"name":"3.47.2","type":"release","directory":"/tmp/fvm/versions/3.47.2","flutterSdkVersion":"3.47.2","isSetup":true},{"name":"3.41.6","type":"release","directory":"/tmp/fvm/versions/3.41.6","flutterSdkVersion":"3.41.6","isSetup":true}]}"#
}
