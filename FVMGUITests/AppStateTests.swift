import XCTest
@testable import fvm_gui

struct MockLocator: ExecutableLocating {
    func locate(manualPath: String?) async throws -> FVMInstallation { FVMInstallation(executable: URL(fileURLWithPath: "/fake/fvm"), version: "4.3.1") }
}
struct MockProjectService: ProjectServicing {
    func inspect(_ url: URL, fvm: any FVMService) async throws -> FlutterProject {
        FlutterProject(path: url.standardizedFileURL.path, name: "example", version: "3.47.2")
    }
}
final class AppStateTests: XCTestCase {
    @MainActor func testUnifiedSDKNavigationRestoresAndMigratesLegacyDestinations() throws {
        let suite = "FVM GUI navigation tests \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("Available Releases", forKey: "app.navigationDestination")
        let migrated = AppWindowCoordinator(defaults: defaults)
        XCTAssertEqual(migrated.selection, .sdks)
        XCTAssertEqual(migrated.selection?.title, "Flutter SDKs")
        XCTAssertEqual(AppDestination.allCases.filter { $0 == .sdks }.count, 1)

        migrated.selection = .projects
        XCTAssertEqual(AppWindowCoordinator(defaults: defaults).selection, .projects)
        XCTAssertEqual(AppDestination.restoring("Storage"), .sdks)
        XCTAssertEqual(AppDestination.restoring("Installed SDKs"), .sdks)
    }

    @MainActor func testProjectPersistenceDeduplicationAndRemoval() async throws {
        let suite = "FVM GUI tests \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executor = MockExecutor([result(#"{"versions":[]}"#), result(#"{"context":{"globalCacheLink":"/tmp/default"}}"#)])
        let app = AppContainer(defaults: defaults, executor: executor, locator: MockLocator(), projectService: MockProjectService())
        await app.detect()
        let projectURL = URL(fileURLWithPath: "/tmp/example")
        await app.addProject(projectURL)
        await app.addProject(projectURL)
        XCTAssertEqual(app.projects.count, 1)
        let next = AppContainer(defaults: defaults)
        XCTAssertEqual(next.projects.count, 1)
        next.removeProject(try XCTUnwrap(next.projects.first))
        XCTAssertTrue(AppContainer(defaults: defaults).projects.isEmpty)
    }
    func testModificationLockAndCancellationRelease() async throws {
        let mock = MockExecutor([result("done")], delay: .seconds(30))
        let service = FVMCLIService(installation: FVMInstallation(executable: URL(fileURLWithPath: "/fake"), version: "4.3.1"), executor: mock)
        let task = Task { try await service.modify(["install", "3.47.2"], directory: nil, output: nil) }
        while await mock.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        do { try await service.modify(["global", "3.47.2"], directory: nil, output: nil); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Another SDK operation")) }
        task.cancel()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        // The next call reaches the executor, rather than the lock rejection.
        let next = Task { try await service.modify(["remove", "3.47.2"], directory: nil, output: nil) }
        while await mock.calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        next.cancel()
        do { try await next.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testActivityCapAndSplitANSI() {
        let store = ActivityStore()
        let id = store.begin(command: "install")
        store.append("\u{001B}[", id: id)
        store.append("31mred\u{001B}[0m", id: id)
        XCTAssertEqual(store.entries.first?.output, "red")
        store.append(String(repeating: "x", count: 300_000), id: id)
        XCTAssertEqual(store.entries.first?.output.count, 200_000)
        for _ in 0..<110 { _ = store.begin(command: "test") }
        XCTAssertEqual(store.entries.count, 100)
    }
    @MainActor func testContextIsNeverLogged() async throws {
        let activity = ActivityStore()
        let executor = LoggingCLIExecutor(base: MockExecutor([result("sensitive environment")]), activity: activity)
        _ = try await executor.run(executable: URL(fileURLWithPath: "/fake"), arguments: ["api", "context"], directory: nil, timeout: .seconds(1), output: nil)
        XCTAssertTrue(activity.entries.isEmpty)
    }
}
