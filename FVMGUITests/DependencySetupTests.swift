import XCTest
@testable import fvm_gui

private let testFVM = FVMInstallation(executable: URL(fileURLWithPath: "/custom/bin/fvm"), version: "4.3.1")
private let testBrew = HomebrewInstallation(executable: URL(fileURLWithPath: "/custom Homebrew/bin/brew"), version: "Homebrew 4.6.0", prefix: URL(fileURLWithPath: "/custom Homebrew"))

private actor SetupFVMLocator: ExecutableLocating {
    private var answers: [Bool]
    var paths: [String?] = []
    init(_ answers: [Bool]) { self.answers = answers }
    func locate(manualPath: String?) async throws -> FVMInstallation {
        paths.append(manualPath)
        guard !answers.isEmpty, answers.removeFirst() else { throw FVMError.message("FVM missing or invalid") }
        return testFVM
    }
}
private actor SetupBrewLocator: HomebrewLocating {
    let available: Bool
    var calls = 0
    init(available: Bool = true) { self.available = available }
    func locate(manualPath: String?) async throws -> HomebrewInstallation {
        calls += 1
        guard available else { throw FVMError.message("Homebrew missing") }
        return testBrew
    }
}
private actor SetupStub: DependencySettingUp {
    var checks: [DependencyStatus]
    var checkCount = 0
    var installCount = 0
    var installError: String?
    var delay: Duration?
    init(checks: [DependencyStatus], installError: String? = nil, delay: Duration? = nil) {
        self.checks = checks; self.installError = installError; self.delay = delay
    }
    func check(fvmPath: String?, brewPath: String?) async throws -> DependencyStatus {
        checkCount += 1
        guard !checks.isEmpty else { throw FVMError.message("No detection response") }
        return checks.removeFirst()
    }
    func installFVM(using brew: HomebrewInstallation, output: OutputHandler?) async throws {
        installCount += 1
        await output?(CLIOutput(text: "Downloading FVM\n", isError: false))
        await output?(CLIOutput(text: "diagnostic\n", isError: true))
        if let delay { try await Task.sleep(for: delay) }
        if let installError { throw FVMError.message(installError) }
    }
}

final class DependencySetupTests: XCTestCase {
    func testWorkingFVMBypassesHomebrewDetection() async throws {
        let brew = SetupBrewLocator(available: false)
        let executor = MockExecutor([])
        let service = DependencySetupService(fvmLocator: SetupFVMLocator([true]), brewLocator: brew, executor: executor)
        let status = try await service.check(fvmPath: nil, brewPath: nil)
        XCTAssertEqual(status.fvm, testFVM)
        let count = await brew.calls
        let calls = await executor.calls
        XCTAssertEqual(count, 0)
        XCTAssertTrue(calls.isEmpty)
    }
    func testMissingFVMAndHomebrewDetectedSeparately() async throws {
        for available in [true, false] {
            let service = DependencySetupService(fvmLocator: SetupFVMLocator([false, false]), brewLocator: SetupBrewLocator(available: available), executor: MockExecutor([]))
            let status = try await service.check(fvmPath: nil, brewPath: nil)
            XCTAssertNil(status.fvm)
            XCTAssertEqual(status.homebrew != nil, available)
            XCTAssertNotNil(status.detail)
        }
    }
    func testCustomBrewPrefixDiscoversFVMOutsidePATH() async throws {
        let fvm = SetupFVMLocator([false, true])
        let service = DependencySetupService(fvmLocator: fvm, brewLocator: SetupBrewLocator(), executor: MockExecutor([]))
        let status = try await service.check(fvmPath: nil, brewPath: testBrew.executable.path)
        XCTAssertEqual(status.fvm, testFVM)
        let paths = await fvm.paths
        XCTAssertEqual(paths.last, "/custom Homebrew/bin/fvm")
    }
    func testInvalidExplicitOverridesFailWithoutInstallation() async throws {
        let brew = SetupBrewLocator()
        let executor = MockExecutor([])
        let service = DependencySetupService(fvmLocator: SetupFVMLocator([false]), brewLocator: brew, executor: executor)
        do { _ = try await service.check(fvmPath: "/invalid/fvm", brewPath: nil); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("FVM")) }
        let count = await brew.calls
        XCTAssertEqual(count, 0)
        let invalidBrew = DependencySetupService(fvmLocator: SetupFVMLocator([false]), brewLocator: SetupBrewLocator(available: false), executor: executor)
        do { _ = try await invalidBrew.check(fvmPath: nil, brewPath: "/invalid/brew"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Homebrew")) }
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testInstallUsesArgumentsAndStreamsBothPipes() async throws {
        let executor = MockExecutor([result("installed")])
        let service = DependencySetupService(fvmLocator: SetupFVMLocator([]), brewLocator: SetupBrewLocator(), executor: executor)
        let collector = OutputCollector()
        try await service.installFVM(using: testBrew, output: { await collector.append($0) })
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments, ["install", "fvm"])
        XCTAssertEqual(calls.first?.executable, testBrew.executable)
        XCTAssertNil(calls.first?.directory)
        let text = await collector.text
        XCTAssertEqual(text, "installed")
    }
    func testInstallNonzeroExitPreservesDetails() async throws {
        let service = DependencySetupService(fvmLocator: SetupFVMLocator([]), brewLocator: SetupBrewLocator(), executor: MockExecutor([result("failed", code: 13, stderr: "Permission denied")]))
        do { try await service.installFVM(using: testBrew, output: nil); XCTFail() }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Permission denied"))
            XCTAssertTrue(error.localizedDescription.contains("13"))
        }
    }
    func testServicePreventsConcurrentInstallationAndReleasesAfterCancellation() async throws {
        let executor = MockExecutor([result("installed")], delay: .seconds(30))
        let service = DependencySetupService(fvmLocator: SetupFVMLocator([]), brewLocator: SetupBrewLocator(), executor: executor)
        let task = Task { try await service.installFVM(using: testBrew, output: nil) }
        while await executor.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        do { try await service.installFVM(using: testBrew, output: nil); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("already running")) }
        do { _ = try await service.check(fvmPath: nil, brewPath: nil); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("still running")) }
        task.cancel()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let next = Task { try await service.installFVM(using: testBrew, output: nil) }
        while await executor.calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        next.cancel()
        do { try await next.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testStateTransitionsAndPostInstallVerification() async {
        let stub = SetupStub(checks: [DependencyStatus(fvm: nil, homebrew: testBrew, detail: "missing"), DependencyStatus(fvm: testFVM, homebrew: testBrew, detail: nil)], delay: .milliseconds(30))
        let model = DependencySetupViewModel(service: stub, activity: ActivityStore())
        XCTAssertEqual(model.state, .checking)
        _ = await model.check(fvmPath: nil, brewPath: nil)
        XCTAssertEqual(model.state, .missingFVM)
        let task = Task { await model.install(fvmPath: nil, brewPath: nil) }
        while !model.output.contains("[stderr] diagnostic") { await Task.yield() }
        XCTAssertEqual(model.state, .installing)
        XCTAssertTrue(model.output.contains("Downloading FVM"))
        XCTAssertTrue(model.output.contains("[stderr] diagnostic"))
        let duplicate = await model.install(fvmPath: nil, brewPath: nil)
        XCTAssertNil(duplicate)
        let found = await task.value
        XCTAssertEqual(found, testFVM)
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.isWorking)
        let count = await stub.installCount
        XCTAssertEqual(count, 1)
    }
    @MainActor func testMissingHomebrewStateNeverInstalls() async {
        let stub = SetupStub(checks: [DependencyStatus(fvm: nil, homebrew: nil, detail: "Install Homebrew")])
        let model = DependencySetupViewModel(service: stub, activity: ActivityStore())
        _ = await model.check(fvmPath: nil, brewPath: nil)
        XCTAssertEqual(model.state, .missingHomebrew)
        let result = await model.install(fvmPath: nil, brewPath: nil)
        XCTAssertNil(result)
        let count = await stub.installCount
        XCTAssertEqual(count, 0)
    }
    @MainActor func testZeroExitWithoutWorkingFVMCannotBecomeReady() async {
        let missing = DependencyStatus(fvm: nil, homebrew: testBrew, detail: "still missing")
        let model = DependencySetupViewModel(service: SetupStub(checks: [missing, missing]), activity: ActivityStore())
        _ = await model.check(fvmPath: nil, brewPath: nil)
        let found = await model.install(fvmPath: nil, brewPath: nil)
        XCTAssertNil(found)
        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.detail?.contains("could not be verified") == true)
    }
    @MainActor func testCancellationKeepsBusyUntilCleanupThenAllowsRetry() async {
        let missing = DependencyStatus(fvm: nil, homebrew: testBrew, detail: nil)
        let stub = SetupStub(checks: [missing, missing], delay: .seconds(30))
        let activity = ActivityStore()
        let model = DependencySetupViewModel(service: stub, activity: activity)
        _ = await model.check(fvmPath: nil, brewPath: nil)
        let task = Task { await model.install(fvmPath: nil, brewPath: nil) }
        while await stub.installCount == 0 { await Task.yield() }
        model.cancel()
        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(model.cancelling)
        _ = await task.value
        XCTAssertEqual(model.state, .failed)
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.detail?.contains("cancelled") == true)
        XCTAssertEqual(activity.entries.first?.status, "Cancelled")
        _ = await model.check(fvmPath: nil, brewPath: nil)
        XCTAssertEqual(model.state, .missingFVM)
    }
    @MainActor func testPermissionFailureState() async {
        let stub = SetupStub(checks: [DependencyStatus(fvm: nil, homebrew: testBrew, detail: nil)], installError: "Permission denied: prefix is not writable")
        let model = DependencySetupViewModel(service: stub, activity: ActivityStore())
        _ = await model.check(fvmPath: nil, brewPath: nil)
        _ = await model.install(fvmPath: nil, brewPath: nil)
        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.detail?.contains("Permission denied") == true)
    }
    @MainActor func testAppLaunchActivatesExistingFVMWithoutOnboarding() async throws {
        let suite = "Setup tests \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = SetupStub(checks: [DependencyStatus(fvm: testFVM, homebrew: nil, detail: nil)])
        let executor = MockExecutor([result(#"{"versions":[]}"#), result(#"{"context":{"globalCacheLink":"/tmp/default"}}"#)])
        let app = AppContainer(defaults: defaults, executor: executor, setupService: stub)
        await app.start()
        await app.start()
        XCTAssertEqual(app.installation, testFVM)
        XCTAssertEqual(app.setup.state, .ready)
        let count = await stub.checkCount
        XCTAssertEqual(count, 1)
    }
}
