import Foundation
import XCTest
@testable import fvm_gui

final class SDKStorageTests: XCTestCase {
    func testMeasuresNestedFilesAndDeduplicatesHardLinksAndSkipsSymlinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = root.appendingPathComponent("cache/custom/3.24.0", isDirectory: true)
        let nested = sdk.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("flutter.framework")
        try Data(repeating: 1, count: 4096).write(to: file)
        try FileManager.default.linkItem(at: file, to: sdk.appendingPathComponent("framework-link"))
        try FileManager.default.createSymbolicLink(at: sdk.appendingPathComponent("outside"), withDestinationURL: root)

        let result = try await SDKStorageService().analyze(sdks: [makeSDK(path: sdk.path)], registeredProjects: [], discoveredProjects: [], forceRefresh: true)

        XCTAssertEqual(result.items[0].logicalSize, 4096)
        XCTAssertEqual(result.items[0].allocatedSize, 4096)
        XCTAssertEqual(result.totalStorage, result.items[0].allocatedSize)
    }

    func testCleanupCandidateIsConservativeAndGlobalSDKIsProtected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("3.24.0")
        let global = root.appendingPathComponent("3.25.0")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 512).write(to: first.appendingPathComponent("a"))
        try Data(repeating: 0, count: 512).write(to: global.appendingPathComponent("b"))

        let result = try await SDKStorageService().analyze(sdks: [makeSDK(path: first.path), makeSDK(path: global.path, global: true)], registeredProjects: [], discoveredProjects: [], forceRefresh: true)

        XCTAssertTrue(result.items.first { $0.version == "3.24.0" }?.isCleanupCandidate == true)
        XCTAssertFalse(result.items.first { $0.version == "3.25.0" }?.isCleanupCandidate == true)
        XCTAssertEqual(result.potentialCleanupSpace, result.items.first { $0.version == "3.24.0" }?.measuredSize)
        XCTAssertEqual(result.storageWithoutKnownReferences, result.items.reduce(UInt64.zero) { $0 + $1.measuredSize })
    }

    func testCountsRegisteredAndDiscoveredReferencesWithoutDoubleCountingProjects() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdkPath = root.appendingPathComponent("sdk").path
        try FileManager.default.createDirectory(atPath: sdkPath, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: sdkPath).appendingPathComponent("file"))
        let registered = FlutterProject(path: root.appendingPathComponent("project/..").standardizedFileURL.path, name: "registered", version: "3.24.0")
        let sameDiscovered = FlutterProject(path: registered.path, name: "registered", version: "3.24.0")
        let discovered = FlutterProject(path: root.appendingPathComponent("other").path, name: "other", version: "3.24.0")
        let dart = FlutterProject(path: root.appendingPathComponent("dart").path, name: "dart", version: "3.24.0", type: .dartPackage)

        let result = try await SDKStorageService().analyze(sdks: [makeSDK(path: sdkPath, version: "3.24.0")], registeredProjects: [registered],
                                                           discoveredProjects: [sameDiscovered, discovered, dart], forceRefresh: true)

        XCTAssertEqual(result.items[0].registeredProjectReferenceCount, 1)
        XCTAssertEqual(result.items[0].discoveredProjectReferenceCount, 1)
        XCTAssertFalse(result.items[0].isCleanupCandidate)
        XCTAssertEqual(result.referencedStorage, result.items[0].measuredSize)
    }

    func testMissingSDKDirectoryIsReportedRatherThanCountedAsCleanupSpace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await SDKStorageService().analyze(sdks: [makeSDK(path: root.appendingPathComponent("missing").path)],
                                                           registeredProjects: [], discoveredProjects: [], forceRefresh: true)
        XCTAssertNotNil(result.items[0].measurementIssue)
        XCTAssertEqual(result.potentialCleanupSpace, 0)
    }

    func testRemovalPolicyProtectsGlobalReferencedAndBusySDKs() {
        let sdk = FlutterSDK(name: "3.24.0", type: "release", directory: "/cache/3.24.0", flutterSdkVersion: "3.24.0", isSetup: true)
        let global = FlutterSDK(name: sdk.name, type: sdk.type, directory: sdk.directory, flutterSdkVersion: sdk.flutterSdkVersion, isSetup: true, isGlobal: true)

        XCTAssertNotNil(SDKRemovalPolicy.blockReason(sdk: global, operationActive: false))
        XCTAssertNotNil(SDKRemovalPolicy.blockReason(sdk: sdk, operationActive: true))
        XCTAssertNil(SDKRemovalPolicy.referenceWarning(sdk: sdk, registeredReferences: 0, discoveredReferences: 0))
        XCTAssertNotNil(SDKRemovalPolicy.referenceWarning(sdk: sdk, registeredReferences: 1, discoveredReferences: 0))
        XCTAssertNotNil(SDKRemovalPolicy.referenceWarning(sdk: sdk, registeredReferences: 0, discoveredReferences: 1))
        XCTAssertNil(SDKRemovalPolicy.blockReason(sdk: sdk, operationActive: false))
    }

    func testCancellationPropagates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = root.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let storageService = SDKStorageService()
        let sdkInfo = makeSDK(path: sdk.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await storageService.analyze(sdks: [sdkInfo], registeredProjects: [], discoveredProjects: [], forceRefresh: true)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    private func makeSDK(path: String, version: String? = nil, global: Bool = false) -> FlutterSDK {
        let name = version ?? URL(fileURLWithPath: path).lastPathComponent
        return FlutterSDK(name: name, type: "release", directory: path,
                          flutterSdkVersion: name, isSetup: true, isGlobal: global)
    }
}
