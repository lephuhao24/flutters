import XCTest
@testable import fvm_gui

private actor DeniedRootFileSystem: FileSystemOperating {
    private let base = LocalFileSystem()
    private let deniedPath: String
    init(deniedPath: String) { self.deniedPath = deniedPath }
    func exists(_ url: URL) async -> Bool { await base.exists(url) }
    func contents(of url: URL) async throws -> [FileSystemEntry] {
        if url.path == deniedPath { throw CocoaError(.fileReadNoPermission) }
        return try await base.contents(of: url)
    }
    func isDirectory(_ url: URL) async -> Bool { await base.isDirectory(url) }
    func isSymbolicLink(_ url: URL) async -> Bool { await base.isSymbolicLink(url) }
    func read(_ url: URL) async throws -> Data { try await base.read(url) }
    func write(_ data: Data, to url: URL) async throws { try await base.write(data, to: url) }
    func createDirectory(_ url: URL) async throws { try await base.createDirectory(url) }
    func remove(_ url: URL) async throws { try await base.remove(url) }
}

private actor DiscoveryProgressSignal {
    private var didReport = false
    func mark() { didReport = true }
    var reported: Bool { didReport }
}

final class ProjectDiscoveryTests: XCTestCase {
    func testDiscoversFlutterAppsPackagesPluginsAndDartPackages() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeProject(root, path: "app", yaml: """
            name: flutter_app
            dependencies:
              flutter:
                sdk: flutter
            environment:
              sdk: '>=3.4.0 <4.0.0'
            """, files: ["lib/main.dart", "ios/Runner.xcodeproj/project.pbxproj", "android/app/build.gradle", "web/index.html"])
        _ = try makeProject(root, path: "package", yaml: """
            name: flutter_package
            dependencies: {flutter: {sdk: flutter}}
            environment: {sdk: '>=3.0.0 <4.0.0'}
            """)
        _ = try makeProject(root, path: "plugin", yaml: """
            name: flutter_plugin
            dependencies:
              flutter: {sdk: flutter}
            flutter:
              plugin:
                platforms:
                  macos:
                    pluginClass: ExamplePlugin
            """)
        _ = try makeProject(root, path: "dart", yaml: """
            name: dart_only
            dependencies:
              collection: ^1.18.0
            environment:
              sdk: ^3.4.0
            """)

        let result = try await ProjectDiscoveryService().scan(roots: [root], maximumDepth: 3, ignoredPaths: [])
        let projects = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.name, $0) })
        XCTAssertEqual(projects["flutter_app"]?.type, .flutterApp)
        XCTAssertEqual(projects["flutter_app"]?.dartSDKConstraint, ">=3.4.0 <4.0.0")
        XCTAssertEqual(projects["flutter_app"]?.platforms, ["ios", "android", "web"])
        XCTAssertEqual(projects["flutter_package"]?.type, .flutterPackage)
        XCTAssertEqual(projects["flutter_plugin"]?.type, .flutterPlugin)
        XCTAssertEqual(projects["dart_only"]?.type, .dartPackage)
    }

    func testNestedProjectsInheritanceDuplicateRootsAndIgnoredPaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent(".fvmrc"), "{\"flutter\":\"3.24.0\"}")
        let parent = try makeProject(root, path: "workspace", yaml: "name: workspace\ndependencies:\n  flutter:\n    sdk: flutter\n", files: ["lib/main.dart"])
        _ = try makeProject(parent, path: "packages/child", yaml: "name: child\ndependencies:\n  flutter: {sdk: flutter}\n")
        let ignored = try makeProject(root, path: "ignored", yaml: "name: ignored\ndependencies:\n  flutter: {sdk: flutter}\n")
        let result = try await ProjectDiscoveryService().scan(roots: [root, parent], maximumDepth: 5, ignoredPaths: [ignored.path])
        XCTAssertEqual(Set(result.projects.map(\.name)), Set(["child", "workspace"]), "issues: \(result.issues); projects: \(result.projects)")
        XCTAssertEqual(result.projects.first(where: { $0.name == "child" })?.configuredVersion, "3.24.0")
        XCTAssertEqual(result.projects.first(where: { $0.name == "child" })?.configurationSource, root.appendingPathComponent(".fvmrc").path)
    }

    func testFVMConfigurationDoesNotInheritOutsideSelectedRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent(".fvmrc"), "flutter: 3.24.0\n")
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let project = try makeProject(selected, path: "app", yaml: "name: app\ndependencies:\n  flutter: {sdk: flutter}\n")
        let result = try await ProjectDiscoveryService().scan(roots: [selected], maximumDepth: 4, ignoredPaths: [])
        XCTAssertEqual(result.projects.first?.path, project.path)
        XCTAssertNil(result.projects.first?.configuredVersion)
        XCTAssertNil(result.projects.first?.configurationSource)
    }

    func testSkipsExcludedDirectoriesSymlinkLoopsAndOutsideTargets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = [".git", ".dart_tool", ".fvm", "build", "Pods", "node_modules"]
        for name in excluded { _ = try makeProject(root, path: "\(name)/project", yaml: "name: \(name.replacingOccurrences(of: ".", with: ""))\ndependencies:\n  flutter: {sdk: flutter}\n") }
        let valid = try makeProject(root, path: "valid", yaml: "name: valid\ndependencies:\n  flutter: {sdk: flutter}\n")
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try makeProject(outside, path: "outside", yaml: "name: outside\ndependencies:\n  flutter: {sdk: flutter}\n")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
        let result = try await ProjectDiscoveryService().scan(roots: [root], maximumDepth: 8, ignoredPaths: [])
        XCTAssertEqual(result.projects.map(\.path), [valid.path])
    }

    func testSymlinkedManifestAndFVMConfigAreNotRead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let target = try makeProject(outside, path: "target", yaml: "name: outside\ndependencies:\n  flutter: {sdk: flutter}\n")
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("pubspec.yaml"), withDestinationURL: target.appendingPathComponent("pubspec.yaml"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".fvmrc"), withDestinationURL: outside.appendingPathComponent("missing-config"))
        let local = try makeProject(root, path: "local", yaml: "name: local\ndependencies:\n  flutter: {sdk: flutter}\n")
        let result = try await ProjectDiscoveryService().scan(roots: [root], maximumDepth: 3, ignoredPaths: [])
        XCTAssertEqual(result.projects.map(\.path), [local.path])
        XCTAssertNil(result.projects.first?.configurationSource)
        XCTAssertTrue(result.issues.contains { $0.id == linked.path })
    }

    func testMalformedManifestIsReportedAndOtherProjectsStillReturn() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed = root.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try write(malformed.appendingPathComponent("pubspec.yaml"), "name: [unterminated\n")
        let good = try makeProject(root, path: "good", yaml: "name: good\ndependencies:\n  flutter: {sdk: flutter}\n")
        let result = try await ProjectDiscoveryService().scan(roots: [root], maximumDepth: 2, ignoredPaths: [])
        XCTAssertEqual(result.projects.map(\.path), [good.path])
        XCTAssertTrue(result.issues.contains { $0.id == malformed.path && $0.message.contains("Malformed pubspec.yaml") })
    }

    func testUnreadableSelectedRootIsReportedWithoutCrashing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ProjectDiscoveryService(fileSystem: DeniedRootFileSystem(deniedPath: root.path))
        let result = try await service.scan(roots: [root], maximumDepth: 2, ignoredPaths: [])
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertTrue(result.issues.first?.message.contains("Cannot read selected directory") == true)
    }

    func testCancellationDuringTraversalThrowsCancellationError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<250 { _ = try makeProject(root, path: "folder-\(index)", yaml: "name: app_\(index)\ndependencies:\n  flutter: {sdk: flutter}\n") }
        let signal = DiscoveryProgressSignal()
        let scan = Task {
            try await ProjectDiscoveryService().scan(roots: [root], maximumDepth: 4, ignoredPaths: []) { _ in await signal.mark() }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await signal.reported), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let didReport = await signal.reported
        XCTAssertTrue(didReport, "Scanner should report progress before cancellation")
        scan.cancel()
        do { _ = try await scan.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testDiscoveryPersistenceAndImportsCanonicalDuplicatesOnce() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FVM GUI tests \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppContainer(defaults: defaults, discoveryService: EmptyDiscoveryService())
        app.approveScanDirectories([root, root.appendingPathComponent(".")])
        let project = FlutterProject(path: root.appendingPathComponent("project").path, name: "demo", type: .flutterPackage)
        app.importDiscoveredProjects([project, project])
        app.ignoreDiscoveredProject(FlutterProject(path: root.appendingPathComponent("ignored").path, name: "ignored"))
        app.discoverProjects(maximumDepth: 2)
        let deadline = ContinuousClock.now + .seconds(5)
        while app.projectDiscovery.status == .idle, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await app.projectDiscovery.wait()
        let restored = AppContainer(defaults: defaults, discoveryService: EmptyDiscoveryService())
        XCTAssertNotNil(restored.lastDiscoveryDate)
        XCTAssertEqual(restored.approvedScanDirectories.count, 1)
        XCTAssertEqual(restored.projects.count, 1)
        XCTAssertEqual(restored.projects.first?.type, .flutterPackage)
        XCTAssertEqual(restored.ignoredProjectPaths.count, 1)
    }

    private func makeProject(_ root: URL, path: String, yaml: String, files: [String] = []) throws -> URL {
        let directory = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(directory.appendingPathComponent("pubspec.yaml"), yaml)
        for file in files {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(url, "fixture")
        }
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }

    private func write(_ url: URL, _ contents: String) throws { try Data(contents.utf8).write(to: url) }
}

private struct EmptyDiscoveryService: ProjectDiscovering {
    func scan(roots: [URL], maximumDepth: Int, ignoredPaths: Set<String>, progress: ProgressHandler?) async throws -> ProjectDiscoveryResult {
        ProjectDiscoveryResult(projects: [], issues: [], scannedDirectories: 0)
    }
}
