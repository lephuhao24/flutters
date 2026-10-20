import Foundation
import XCTest
@testable import fvm_gui

final class ProjectCompatibilityTests: XCTestCase {
    func testManifestReadsDartAndFlutterConstraintsWithYAMLParser() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("void main() {}".utf8).write(to: root.appendingPathComponent("lib/main.dart"))
        let manifest = """
        name: compatible_app
        dependencies:
          flutter:
            sdk: flutter
        environment:
          sdk: '>=3.8.0-0 <4.0.0 || =4.5.0'
          flutter: '^3.24.0'
        """

        let parsed = try ProjectManifestParser().parse(Data(manifest.utf8), directory: root)

        XCTAssertEqual(parsed.type, .flutterApp)
        XCTAssertEqual(parsed.dartSDKConstraint, ">=3.8.0-0 <4.0.0 || =4.5.0")
        XCTAssertEqual(parsed.flutterSDKConstraint, "^3.24.0")
    }

    func testMetadataUsesFlutterAndBundledDartVersionFilesAndInvalidatesWhenChanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try makeSDK(at: root, version: "3.24.1")
        let dartVersionFile = URL(fileURLWithPath: sdk.directory).appendingPathComponent("bin/cache/dart-sdk/version")
        try FileManager.default.createDirectory(at: dartVersionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("3.5.4\n".utf8).write(to: dartVersionFile)
        try Data("3.24.1\n".utf8).write(to: URL(fileURLWithPath: sdk.directory).appendingPathComponent("version"))
        let service = FlutterSDKMetadataService(executor: NeverRunExecutor())

        let first = await service.metadata(for: sdk, forceRefresh: false)
        try Data("3.6.0\n".utf8).write(to: dartVersionFile)
        let changed = await service.metadata(for: sdk, forceRefresh: false)

        XCTAssertEqual(first.flutterVersion, "3.24.1")
        XCTAssertEqual(first.dartSDKVersion, "3.5.4")
        XCTAssertEqual(changed.dartSDKVersion, "3.6.0")
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
    }

    func testPubEvaluatorForwardsExactCaretRangeAlternativeAndPrereleaseConstraintsOffline() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try makeSDK(at: root, version: "3.24.1")
        let metadata = metadataFor(sdk, dart: "3.5.4")
        let constraints = ["=3.5.4", "^3.5.0", ">=3.4.0 <4.0.0", ">=3.4.0 <4.0.0 || =4.2.0", ">=3.6.0-0 <4.0.0"]
        let executor = RecordingPubExecutor(responses: constraints.map { _ in result("") })
        let evaluator = PubConstraintEvaluator(executor: executor)

        for constraint in constraints {
            let outcome = await evaluator.evaluate(sdk: sdk, metadata: metadata, dartConstraint: constraint, flutterConstraint: "^3.24.0")
            XCTAssertEqual(outcome, .compatible)
        }

        let invocations = await executor.invocations
        XCTAssertEqual(invocations.count, constraints.count)
        XCTAssertTrue(invocations.allSatisfy { $0.arguments == ["pub", "get", "--offline"] })
        XCTAssertEqual(invocations.map(\.dartConstraint), constraints)
        XCTAssertTrue(invocations.allSatisfy { $0.flutterConstraint == "^3.24.0" })
        XCTAssertTrue(invocations.allSatisfy { $0.manifestName == "fvm_gui_compatibility_probe" })
    }

    func testPubSolverFailureIsIncompatibleAndInvalidConstraintIsUnableToEvaluate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = try makeSDK(at: root, version: "3.24.1")
        let metadata = metadataFor(sdk, dart: "3.5.4")
        let incompatible = PubConstraintEvaluator(executor: RecordingPubExecutor(responses: [result("Because probe requires SDK version >=4.0.0, version solving failed.", code: 1)]))
        let invalid = PubConstraintEvaluator(executor: RecordingPubExecutor(responses: [result("Invalid version constraint: malformed", code: 1)]))

        let incompatibleResult = await incompatible.evaluate(sdk: sdk, metadata: metadata, dartConstraint: ">=4.0.0", flutterConstraint: nil)
        XCTAssertEqual(incompatibleResult, .incompatible("Because probe requires SDK version >=4.0.0, version solving failed."))
        guard case .unableToEvaluate = await invalid.evaluate(sdk: sdk, metadata: metadata, dartConstraint: "bad", flutterConstraint: nil) else {
            return XCTFail("Malformed constraints must not be reported as incompatible or compatible")
        }
    }

    func testInheritedFVMConfigurationAndCompatibleResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("name: inherited_app\ndependencies:\n  flutter:\n    sdk: flutter\nenvironment:\n  sdk: '>=3.4.0 <4.0.0'\n".utf8)
            .write(to: projectURL.appendingPathComponent("pubspec.yaml"))
        let inheritedConfig = root.appendingPathComponent(".fvmrc")
        try Data(#"{"flutter":"3.24.1"}"#.utf8).write(to: inheritedConfig)
        let project = try await ProjectManifestReader().read(projectURL, within: root)
        let sdk = try makeSDK(at: root.appendingPathComponent("sdk"), version: "3.24.1")
        let metadata = metadataFor(sdk, dart: "3.5.4")
        let service = ProjectCompatibilityService(metadataService: FixedMetadataProvider(metadata),
                                                  constraintEvaluator: FixedConstraintEvaluator(.compatible))

        let result = await service.evaluate(project: project, sdk: sdk, installedSDKs: [sdk])

        XCTAssertEqual(result.status, .compatible)
        XCTAssertEqual(result.configuredFlutterVersion, "3.24.1")
        XCTAssertEqual(result.configurationSource, inheritedConfig.path)
        XCTAssertEqual(result.selectedFlutterVersion, "3.24.1")
        XCTAssertEqual(result.bundledDartSDKVersion, "3.5.4")
    }

    func testMalformedManifestAndMissingMetadataAreNeverCompatible() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("name: [bad yaml\n".utf8).write(to: projectURL.appendingPathComponent("pubspec.yaml"))
        let project = FlutterProject(path: projectURL.path, name: "app")
        let sdk = try makeSDK(at: root.appendingPathComponent("sdk"), version: "3.24.1")
        let malformedService = ProjectCompatibilityService(metadataService: FixedMetadataProvider(metadataFor(sdk, dart: "3.5.4")),
                                                           constraintEvaluator: FixedConstraintEvaluator(.compatible))
        let malformed = await malformedService.evaluate(project: project, sdk: sdk, installedSDKs: [sdk])
        XCTAssertEqual(malformed.status, .unableToEvaluate)

        try Data("name: app\ndependencies:\n  flutter:\n    sdk: flutter\nenvironment:\n  sdk: '^3.0.0'\n".utf8)
            .write(to: projectURL.appendingPathComponent("pubspec.yaml"))
        let missingMetadata = FlutterSDKMetadata(sdkName: sdk.name, directory: sdk.directory, flutterVersion: nil,
                                                 dartSDKVersion: nil, isInstalled: true, isSetup: true,
                                                 fingerprint: "missing", issue: "SDK metadata missing")
        let missingService = ProjectCompatibilityService(metadataService: FixedMetadataProvider(missingMetadata),
                                                         constraintEvaluator: FixedConstraintEvaluator(.compatible))
        let unknown = await missingService.evaluate(project: project, sdk: sdk, installedSDKs: [sdk])
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertNotEqual(unknown.status, .compatible)
    }

    func testProjectConstraintAndFVMChangesInvalidateCachedCompatibility() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let manifestURL = projectURL.appendingPathComponent("pubspec.yaml")
        try Data("name: app\ndependencies:\n  flutter:\n    sdk: flutter\nenvironment:\n  sdk: '^3.0.0'\n".utf8).write(to: manifestURL)
        let configURL = projectURL.appendingPathComponent(".fvmrc")
        try Data(#"{"flutter":"3.24.1"}"#.utf8).write(to: configURL)
        let project = try await ProjectManifestReader().read(projectURL, within: root)
        let sdk = try makeSDK(at: root.appendingPathComponent("sdk"), version: "3.24.1")
        let evaluator = CountingConstraintEvaluator()
        let service = ProjectCompatibilityService(metadataService: FixedMetadataProvider(metadataFor(sdk, dart: "3.5.4")), constraintEvaluator: evaluator)

        _ = await service.evaluate(project: project, sdk: sdk, installedSDKs: [sdk])
        try Data("name: app\ndependencies:\n  flutter:\n    sdk: flutter\nenvironment:\n  sdk: '^4.0.0'\n".utf8).write(to: manifestURL)
        try Data(#"{"flutter":"3.25.0"}"#.utf8).write(to: configURL)
        _ = await service.evaluate(project: project, sdk: sdk, installedSDKs: [sdk])

        let calls = await evaluator.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.dartConstraint, "^4.0.0")
    }

    @MainActor func testSDKSwitchingSuggestionsUseCompatibleInstalledVersions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("name: app\ndependencies:\n  flutter:\n    sdk: flutter\nenvironment:\n  sdk: '^3.0.0'\n".utf8).write(to: projectURL.appendingPathComponent("pubspec.yaml"))
        let project = FlutterProject(path: projectURL.path, name: "app", version: "3.24.1")
        let sdkA = try makeSDK(at: root.appendingPathComponent("3.24.1"), version: "3.24.1")
        let sdkB = try makeSDK(at: root.appendingPathComponent("3.27.0"), version: "3.27.0")
        let service = ProjectCompatibilityViewModel(service: VersionedCompatibilityService(incompatibleSDKs: [sdkA.name]))

        await service.refresh(projects: [project], sdks: [sdkA, sdkB])
        let suggestions = await service.compatibleSuggestions(for: project, excluding: sdkA.name)

        XCTAssertEqual(service.result(for: project)?.status, .incompatible)
        XCTAssertEqual(suggestions, [sdkB.name])
    }

    private func makeSDK(at directory: URL, version: String) throws -> FlutterSDK {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return FlutterSDK(name: version, type: "release", directory: directory.path,
                          flutterSdkVersion: version, isSetup: true)
    }

    private func metadataFor(_ sdk: FlutterSDK, dart: String) -> FlutterSDKMetadata {
        FlutterSDKMetadata(sdkName: sdk.name, directory: sdk.directory, flutterVersion: sdk.flutterSdkVersion,
                           dartSDKVersion: dart, isInstalled: true, isSetup: true,
                           fingerprint: "\(sdk.name)-\(dart)", issue: nil)
    }
}

private actor NeverRunExecutor: CLIExecuting {
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        throw FVMError.message("The metadata files should avoid a CLI fallback in this test.")
    }
}

private actor RecordingPubExecutor: CLIExecuting {
    struct Invocation: Sendable {
        let arguments: [String]
        let dartConstraint: String?
        let flutterConstraint: String?
        let manifestName: String?
    }
    private(set) var invocations: [Invocation] = []
    private var responses: [CLIResult]
    init(responses: [CLIResult]) { self.responses = responses }

    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        let manifest = directory?.appendingPathComponent("pubspec.yaml")
        let data = manifest.flatMap { try? Data(contentsOf: $0) }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let environment = object?["environment"] as? [String: String]
        invocations.append(Invocation(arguments: arguments, dartConstraint: environment?["sdk"],
                                       flutterConstraint: environment?["flutter"], manifestName: object?["name"] as? String))
        guard !responses.isEmpty else { throw FVMError.message("No mock Pub response") }
        return responses.removeFirst()
    }
}

private actor FixedMetadataProvider: FlutterSDKMetadataProviding {
    let value: FlutterSDKMetadata
    init(_ value: FlutterSDKMetadata) { self.value = value }
    func metadata(for sdk: FlutterSDK, forceRefresh: Bool) async -> FlutterSDKMetadata { value }
}

private actor FixedConstraintEvaluator: PubConstraintEvaluating {
    let outcome: PubConstraintEvaluation
    init(_ outcome: PubConstraintEvaluation) { self.outcome = outcome }
    func evaluate(sdk: FlutterSDK, metadata: FlutterSDKMetadata, dartConstraint: String, flutterConstraint: String?) async -> PubConstraintEvaluation { outcome }
}

private actor CountingConstraintEvaluator: PubConstraintEvaluating {
    private(set) var calls: [(dartConstraint: String, flutterConstraint: String?)] = []
    func evaluate(sdk: FlutterSDK, metadata: FlutterSDKMetadata, dartConstraint: String, flutterConstraint: String?) async -> PubConstraintEvaluation {
        calls.append((dartConstraint, flutterConstraint))
        return .compatible
    }
}

private actor VersionedCompatibilityService: ProjectCompatibilityServicing {
    let incompatibleSDKs: Set<String>
    init(incompatibleSDKs: Set<String>) { self.incompatibleSDKs = incompatibleSDKs }
    func evaluate(project: FlutterProject, sdk: FlutterSDK?, installedSDKs: [FlutterSDK], forceRefresh: Bool) async -> ProjectCompatibility {
        let status: ProjectCompatibilityStatus = sdk.map { incompatibleSDKs.contains($0.name) ? .incompatible : .compatible } ?? .sdkMissing
        return ProjectCompatibility(projectName: project.name, projectPath: project.path, configurationSource: project.configurationSource,
                                    configuredFlutterVersion: project.configuredVersion, effectiveFlutterVersion: project.effectiveVersion,
                                    selectedFlutterSDK: sdk?.name, selectedFlutterVersion: sdk?.flutterSdkVersion,
                                    bundledDartSDKVersion: "3.5.4", requiredDartConstraint: "^3.0.0", requiredFlutterConstraint: nil,
                                    status: status, explanation: status.title, recommendedAction: "Choose another SDK.")
    }
}
