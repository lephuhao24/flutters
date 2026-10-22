import XCTest
import ZIPFoundation
@testable import fvm_gui

final class BuildReleaseTests: XCTestCase {

    // MARK: - Existing Build Release Tests

    @MainActor
    func testBuildStoreReceivesLiveOutputAndPersistsFullJobLog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let sdk = root.appendingPathComponent("sdk", isDirectory: true)
        let fvm = root.appendingPathComponent("fvm")
        let flutter = sdk.appendingPathComponent("bin/flutter")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("android/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flutter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "name: fixture".write(to: project.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
        try "void main() {}".write(to: project.appendingPathComponent("lib/main.dart"), atomically: true, encoding: .utf8)
        for executable in [fvm, flutter] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let suite = "BuildRelease live log \(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildReleaseStore(defaults: defaults)
        let service = FlutterBuildService(
            fvm: FVMInstallation(executable: fvm, version: "fixture"),
            sdkDirectory: sdk.path,
            executor: IncrementalBuildExecutor()
        )
        let config = BuildConfiguration(projectID: project.path, sdkVersion: "fixture", archiveRelease: false)

        store.start(config: config, project: project, sdkLabel: "fixture", service: service)
        let task = try XCTUnwrap(store.activeTask)
        let deadline = ContinuousClock.now + .seconds(5)
        while !store.liveLog.contains("incremental stdout") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.activeTask != nil, "The subprocess should still be running when its first log line arrives.")
        XCTAssertTrue(store.liveLog.contains("incremental stdout"))
        await task.value

        let record = try XCTUnwrap(store.history.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(store.readLog(record).contains("incremental stdout"))
    }

    func testTypedAndroidArgumentsKeepValuesAsSeparateArguments() throws {
        var config = BuildConfiguration(projectID: "/tmp/project", sdkVersion: "3.24.0")
        config.platform = .androidAPK; config.flavor = "uatBlue"; config.entrypoint = "lib/main_uat.dart"
        config.buildName = "1.2.0"; config.buildNumber = "17"; config.defines = [BuildDefine(key: "API_BASE_URL", value: "https://example.com/a b")]
        config.obfuscate = true; config.splitDebugInfo = "/tmp/symbols"; config.splitPerABI = true
        let args = try config.arguments()
        XCTAssertEqual(args.prefix(7), ["build", "apk", "--release", "-t", "lib/main_uat.dart", "--flavor", "uatBlue"])
        XCTAssertTrue(args.contains("API_BASE_URL=https://example.com/a b"))
        XCTAssertTrue(args.contains("--split-per-abi")); XCTAssertTrue(args.contains("--obfuscate"))
        XCTAssertFalse(args.contains("https://example.com/a"))
    }

    func testFlutterCLIOptionParserRecognizesConfirmedDeclarationsAndNormalizesValues() {
        let help = """
        Usage: flutter build ipa [arguments]
          --[no-]tree-shake-icons    Tree shake icons.
          --split-debug-info=<v1.2.3/>  A directory where debugging information can be stored.
          --[no-]obfuscate            Obfuscate Dart code.
          --build-name=<x.y.z>        A value taking option.
          -t, --target=<path>         Main entrypoint.
          This description mentions --split-debug-info and --obfuscate but declares neither.
        """
        let flags = FlutterCLIOptionParser().parse(help)
        XCTAssertTrue(flags.isSuperset(of: Set(["--obfuscate", "--no-obfuscate", "--tree-shake-icons", "--no-tree-shake-icons", "--split-debug-info", "--build-name", "--target"])))
        XCTAssertFalse(flags.contains("--this-description"))
        XCTAssertEqual(flags.filter { $0.contains("split-debug-info") }, ["--split-debug-info"])
    }

    func testFlutterCLIOptionParserIgnoresDescriptionOnlyFlagMentions() {
        let help = """
        Usage: flutter build apk [arguments]
          --release              Build a release version.
          This option works with --obfuscate and requires --split-debug-info=<directory>.
          Do not enable --tree-shake-icons for this configuration.
        """
        XCTAssertEqual(FlutterCLIOptionParser().parse(help), ["--release"])
    }

    func testFlutterCLIOptionParserRecognizesAndroidAPKBuildOptions() {
        let declarations = """
        Usage: flutter build apk [arguments]
          --[no-]tree-shake-icons
          --split-debug-info=<v1.2.3/>
          --[no-]obfuscate
        """
        let flags = FlutterCLIOptionParser().parse(declarations)
        XCTAssertTrue(flags.isSuperset(of: Set(["--obfuscate", "--no-obfuscate", "--tree-shake-icons", "--no-tree-shake-icons", "--split-debug-info"])))
    }

    func testFlutterOptionCacheInvalidatesOldSchemaFalseNegatives() throws {
        let suite = "FlutterOptionCacheMigration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("legacy false negative".utf8), forKey: "buildRelease.flutterOptionCapabilities.schema1")
        let cache = FlutterOptionCapabilityCache(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "buildRelease.flutterOptionCapabilities.schema1"))
        let identity = FlutterSDKIdentity(executable: URL(fileURLWithPath: "/tmp/flutter"), sdkVersion: "3.47.7")
        XCTAssertNil(cache.probe(for: identity, target: "ipa"))
    }

    func testObfuscationRequiresSplitDebugInfoDirectory() {
        var config = BuildConfiguration(projectID: "/tmp/project", sdkVersion: "3.47.7")
        config.obfuscate = true
        XCTAssertThrowsError(try config.arguments()) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("split debug info"))
        }
        config.splitDebugInfo = "  /tmp/symbols  "
        XCTAssertNoThrow(try config.arguments())
        XCTAssertTrue((try? config.arguments())?.contains("/tmp/symbols") == true)
    }

    func testSplitDebugInfoCanBeEnabledWithoutObfuscation() throws {
        var config = BuildConfiguration(projectID: "/tmp/project", sdkVersion: "3.47.7")
        config.generateDebugSymbols = true
        config.splitDebugInfo = "/tmp/release-symbols"
        let arguments = try config.arguments()
        XCTAssertFalse(arguments.contains("--obfuscate"))
        let splitFlagIndex = try XCTUnwrap(arguments.firstIndex(of: "--split-debug-info"))
        XCTAssertEqual(arguments[splitFlagIndex + 1], "/tmp/release-symbols")
    }

    func testReleaseStorageUsesApplicationSupportAndBuildScopedUniqueFolders() async throws {
        let defaultURL = try ReleaseStorageService.defaultStorageURL()
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertTrue(defaultURL.path.hasPrefix(appSupport.path))
        XCTAssertEqual(defaultURL.lastPathComponent, "Releases")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("A project with spaces")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("build/app/outputs/flutter-apk"), withIntermediateDirectories: true)
        try "name: same_name\n".write(to: project.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
        try "[remote \"origin\"]\n  url = https://example.test/team/project.git\n".write(to: project.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        let custom = root.appendingPathComponent("custom Releases", isDirectory: true)
        let suite = "ReleaseStorage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ReleaseStorageService(defaultsBox: ReleaseStorageDefaults(defaults))
        try await storage.configureStorageLocation(custom, bookmark: nil)

        var config = BuildConfiguration(projectID: project.path, platform: .androidAPK, sdkVersion: "3.47.7", flavor: "../dev", buildName: "5.3.3", buildNumber: "1")
        config.obfuscate = true
        config.generateDebugSymbols = true
        let firstID = UUID()
        let first = try await storage.prepareReleaseDirectory(for: config, project: project, projectName: "same display name", buildID: firstID)
        let second = try await storage.prepareReleaseDirectory(for: config, project: project, projectName: "same display name", buildID: UUID())
        XCTAssertNotEqual(first.rootURL, second.rootURL)
        XCTAssertFalse(first.rootURL.path.hasPrefix(project.appendingPathComponent("build").path))
        XCTAssertTrue(first.rootURL.path.contains("project-"))
        XCTAssertFalse(first.rootURL.path.contains("../dev"))
        do {
            _ = try await storage.prepareReleaseDirectory(for: config, project: project, projectName: "same display name", buildID: firstID)
            XCTFail("A duplicate build ID must never reuse or overwrite a release folder.")
        } catch is ReleaseStorageError { }

        let sourceArtifact = project.appendingPathComponent("build/app/outputs/flutter-apk/app-release.apk")
        try Data("apk contents".utf8).write(to: sourceArtifact)
        let archived = try await storage.archiveArtifacts([sourceArtifact], to: first)
        XCTAssertEqual(archived.map(\.fileName), ["app-release.apk"])
        let symbols = first.symbolsURL.appendingPathComponent("app.android-arm64.symbols")
        try Data("real symbol mapping".utf8).write(to: symbols)
        let foundSymbols = try await storage.discoverSymbols(in: first)
        XCTAssertEqual(foundSymbols, ["symbols/app.android-arm64.symbols"])
        do {
            _ = try await storage.archiveArtifacts([sourceArtifact], to: first)
            XCTFail("Existing archive files must not be overwritten.")
        } catch { }

        let metadata = ReleaseMetadata(
            schemaVersion: 1, buildID: firstID, projectID: first.projectID, projectName: "same display name",
            platform: .androidAPK, target: "apk", flavor: config.flavor, entrypoint: config.entrypoint,
            buildName: config.buildName, buildNumber: config.buildNumber, flutterVersion: "3.47.7",
            flutterExecutablePath: "/sdk/bin/flutter", dartVersion: "Dart 3.11", gitCommit: nil,
            gitBranch: nil, obfuscationEnabled: true, splitDebugInfoEnabled: true, createdAt: Date(),
            durationSeconds: 2, buildResult: .succeeded, archiveResult: .archived,
            buildArguments: ["build", "apk", "--obfuscate", "--split-debug-info", "symbols"],
            artifacts: archived, symbolFiles: ["symbols/app.android-arm64.symbols"], warnings: []
        )
        try await storage.saveBuildMetadata(metadata, to: first)
        let loaded = try await storage.loadMetadata(at: first.rootURL)
        let releases = try await storage.listReleases(for: first.projectID)
        XCTAssertEqual(loaded.buildID, firstID)
        XCTAssertEqual(releases.count, 1)
        let zip = root.appendingPathComponent("release.zip")
        try await storage.exportRelease(at: first.rootURL, destination: zip, contents: .complete)
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(archive.reduce(into: 0) { count, _ in count += 1 }, 3, "Complete export should contain artifact, symbols, and metadata when present.")
    }

    func testStableReleaseProjectIdentitySurvivesMoveAndSeparatesDifferentRepositories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func makeProject(_ path: URL, remote: String) throws {
            try FileManager.default.createDirectory(at: path.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try "name: duplicate_name\n".write(to: path.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
            try "[remote \"origin\"]\n  url = \(remote)\n".write(to: path.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        }
        let original = root.appendingPathComponent("first")
        let moved = root.appendingPathComponent("moved")
        let other = root.appendingPathComponent("other")
        try makeProject(original, remote: "https://example.test/a/repo.git")
        try makeProject(moved, remote: "https://example.test/a/repo.git")
        try makeProject(other, remote: "https://example.test/b/repo.git")
        XCTAssertEqual(ReleaseStorageService.stableProjectID(at: original, projectName: "Duplicate"), ReleaseStorageService.stableProjectID(at: moved, projectName: "Duplicate"))
        XCTAssertNotEqual(ReleaseStorageService.stableProjectID(at: original, projectName: "Duplicate"), ReleaseStorageService.stableProjectID(at: other, projectName: "Duplicate"))
        XCTAssertNotEqual(ReleaseStorageService.safeComponent("../../a name"), "../../a name")
    }

    @MainActor
    func testBuildReleasePipelineArchivesArtifactsAndObfuscationSymbolsOutsideFlutterBuild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("flutter-project", isDirectory: true)
        let sdkDirectory = root.appendingPathComponent("sdk", isDirectory: true)
        let flutter = sdkDirectory.appendingPathComponent("bin/flutter")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("android/app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flutter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "name: pipeline_fixture\n".write(to: project.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
        try "void main() {}\n".write(to: project.appendingPathComponent("lib/main.dart"), atomically: true, encoding: .utf8)
        try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'Flutter 3.47.7 • Dart 3.11.0'; fi\n".utf8).write(to: flutter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flutter.path)

        let suite = "BuildReleaseArchivePipeline.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archiveRoot = root.appendingPathComponent("release-archive", isDirectory: true)
        let storage = ReleaseStorageService(defaultsBox: ReleaseStorageDefaults(defaults))
        try await storage.configureStorageLocation(archiveRoot, bookmark: nil)
        let store = BuildReleaseStore(defaults: defaults, releaseStorage: storage)
        let service = FlutterBuildService(
            fvm: FVMInstallation(executable: root.appendingPathComponent("fvm"), version: "fixture"),
            sdkDirectory: sdkDirectory.path,
            executor: ArchivePipelineExecutor()
        )
        var config = BuildConfiguration(projectID: project.path, platform: .androidAPK, sdkVersion: "3.47.7")
        config.obfuscate = true
        config.defines = [BuildDefine(key: "API_TOKEN", value: "must-not-be-persisted")]
        let buildID = UUID()
        store.start(config: config, project: project, projectName: "pipeline_fixture", sdkLabel: "3.47.7", service: service, buildID: buildID)
        let task = try XCTUnwrap(store.activeTask)
        await task.value

        let record = try XCTUnwrap(store.history.first)
        XCTAssertNil(record.error, record.error ?? "")
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.archiveStatus, .archived)
        XCTAssertEqual(record.id, buildID)
        XCTAssertEqual(record.archivedArtifacts?.count, 1)
        XCTAssertEqual(record.archivedSymbolFiles?.count, 1)
        let releaseURL = URL(fileURLWithPath: try XCTUnwrap(record.releaseDirectory), isDirectory: true)
        XCTAssertFalse(releaseURL.path.hasPrefix(project.appendingPathComponent("build").path))
        let metadata = try await storage.loadMetadata(at: releaseURL)
        XCTAssertTrue(metadata.obfuscationEnabled)
        XCTAssertTrue(metadata.splitDebugInfoEnabled)
        XCTAssertTrue(metadata.buildArguments.contains("--obfuscate"))
        XCTAssertFalse(metadata.buildArguments.contains("must-not-be-persisted"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: releaseURL.appendingPathComponent("artifacts/app-release.apk").path))
        XCTAssertEqual(metadata.symbolFiles.count, 1)

        try FileManager.default.removeItem(at: project.appendingPathComponent("build"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: releaseURL.appendingPathComponent("artifacts/app-release.apk").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: releaseURL.appendingPathComponent(metadata.symbolFiles[0]).path))
    }

    func testCapabilityProbeAndBuildUseSelectedFlutterExecutableAndSameArguments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sdk = root.appendingPathComponent("selected-sdk", isDirectory: true)
        let executable = sdk.appendingPathComponent("bin/flutter")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let fvm = URL(fileURLWithPath: "/different/fvm")
        let recorder = RecordingBuildExecutor()
        let service = FlutterBuildService(fvm: FVMInstallation(executable: fvm, version: "fixture"), sdkDirectory: sdk.path, executor: recorder)
        let config = BuildConfiguration(projectID: root.path, platform: .iOSIPA, sdkVersion: "3.47.7")
        let probe = try await service.probeOptions(executable: executable, sdkVersion: "3.47.7", target: "ipa", project: root, requested: ["--obfuscate", "--tree-shake-icons", "--split-debug-info"])
        XCTAssertEqual(probe.states, ["--obfuscate": .supported, "--tree-shake-icons": .supported, "--split-debug-info": .supported])
        let buildArgs = try config.arguments()
        _ = try await service.run(config, project: root, output: nil)
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.executable), [executable, executable])
        XCTAssertEqual(calls[0].arguments, ["build", "ipa", "-h", "-v"])
        XCTAssertEqual(calls[1].arguments, buildArgs)
        XCTAssertEqual(config.preview, buildArgs.map { $0.rangeOfCharacter(from: .whitespaces) == nil ? $0 : "\"\($0)\"" }.joined(separator: " "))
    }

    func testAndroidAPKCapabilityProbeUsesSameOptionParser() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("sdk/bin/flutter")
        let recorder = RecordingBuildExecutor()
        let service = FlutterBuildService(
            fvm: FVMInstallation(executable: URL(fileURLWithPath: "/different/fvm"), version: "fixture"),
            sdkDirectory: executable.deletingLastPathComponent().deletingLastPathComponent().path,
            executor: recorder
        )
        let probe = try await service.probeOptions(
            executable: executable,
            sdkVersion: "3.47.7",
            target: "apk",
            project: root,
            requested: ["--obfuscate", "--tree-shake-icons", "--split-debug-info"]
        )
        XCTAssertEqual(probe.states, ["--obfuscate": .supported, "--tree-shake-icons": .supported, "--split-debug-info": .supported])
        XCTAssertTrue(probe.isComplete)
    }

    func testFailedAndUnparseableCapabilityResponsesRemainUnknownAndUncached() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("sdk/bin/flutter")
        let responses = [
            CLIResult(exitCode: 1, stdout: "Usage: flutter build ipa [arguments]\n  --[no-]obfuscate", stderr: "probe failed"),
            CLIResult(exitCode: 0, stdout: "Usage: flutter build ipa [arguments]\nNo option declarations were returned.", stderr: "")
        ]
        for (index, response) in responses.enumerated() {
            let suite = "FlutterUnknownProbe.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let cache = FlutterOptionCapabilityCache(defaults: defaults)
            let service = FlutterBuildService(
                fvm: FVMInstallation(executable: URL(fileURLWithPath: "/different/fvm"), version: "fixture"),
                sdkDirectory: executable.deletingLastPathComponent().deletingLastPathComponent().path,
                executor: StaticCapabilityExecutor(response: response),
                capabilityCache: cache
            )
            let probe = try await service.probeOptions(executable: executable, sdkVersion: "3.47.7", target: "ipa", project: root, requested: ["--obfuscate"])
            XCTAssertEqual(probe.states["--obfuscate"], .unknown, "Response case \(index) must not prove the flag unsupported.")
            XCTAssertFalse(probe.cacheHit)
            XCTAssertFalse(probe.isComplete)
            XCTAssertNil(cache.probe(for: FlutterSDKIdentity(executable: executable, sdkVersion: "3.47.7"), target: "ipa"))
        }
    }

    func testSelectedFlutter3477PassesCompleteIOSIPAValidation() async throws {
        let sdkDirectory = URL(fileURLWithPath: "/Users/unit/fvm/versions/3.47.7", isDirectory: true)
        let flutter = sdkDirectory.appendingPathComponent("bin/flutter")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: flutter.path), "Selected Flutter 3.47.7 SDK is not installed on this machine")

        let project = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        try "name: capability_probe_fixture\n".write(to: project.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "void main() {}\n".write(to: project.appendingPathComponent("lib/main.dart"), atomically: true, encoding: .utf8)
        try createIOSProjectFixture(
            at: project,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Profile", "Release"],
            schemes: [("Runner", "Debug", "Release", "Profile")]
        )
        let suite = "Flutter3477CapabilityProbe.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FlutterBuildService(
            fvm: FVMInstallation(executable: URL(fileURLWithPath: "/opt/homebrew/bin/fvm"), version: "fixture"),
            sdkDirectory: sdkDirectory.path,
            executor: CLIExecutor(),
            capabilityCache: FlutterOptionCapabilityCache(defaults: defaults)
        )
        var config = BuildConfiguration(projectID: project.path, platform: .iOSIPA, sdkVersion: "3.47.7")
        config.obfuscate = true
        config.splitDebugInfo = project.appendingPathComponent("symbols").path
        config.treeShakeIcons = true

        try await service.validate(config, project: project)
        let requested = FlutterBuildService.requestedOptions(for: config)
        let probe = try await service.probeOptions(executable: flutter, sdkVersion: config.sdkVersion, target: "ipa", project: project, requested: requested)
        XCTAssertTrue(probe.cacheHit)
        XCTAssertEqual(probe.states["--obfuscate"], .supported)
        XCTAssertEqual(probe.states["--tree-shake-icons"], .supported)
        XCTAssertEqual(probe.states["--split-debug-info"], .supported)
    }

    func testPlatformRejectsAndroidOnlySplitOption() {
        var config = BuildConfiguration(projectID: "test", platform: .iOSIPA, sdkVersion: "stable")
        config.splitPerABI = true
        XCTAssertThrowsError(try config.arguments())
    }

    func testEntrypointDiscoveryOnlySuggestsFilesWithMainFunction() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "void main() {}".write(to: root.appendingPathComponent("lib/main.dart"), atomically: true, encoding: .utf8)
        try "void helper() {}".write(to: root.appendingPathComponent("lib/main_not_executable.dart"), atomically: true, encoding: .utf8)
        try "void main() {}".write(to: root.appendingPathComponent("lib/main_uat.dart"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DartEntrypointDiscovery().discover(project: root), ["lib/main.dart", "lib/main_uat.dart"])
    }

    func testAndroidFlavorDiscoverySupportsGroovyAndKotlinDimensions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("android/app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let groovy = """
        android {
          flavorDimensions "environment", "client"
          productFlavors {
            dev { dimension "environment" }
            prod { dimension "environment" }
            blue { dimension "client" }
            green { dimension "client" }
          }
        }
        """
        try groovy.write(to: app.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        let found = FlavorDiscoveryService().android(project: root).map(\.name)
        XCTAssertEqual(found.sorted(), ["devblue", "devgreen", "prodblue", "prodgreen"])
        try FileManager.default.removeItem(at: app.appendingPathComponent("build.gradle"))
        let kotlin = """
        android {
          flavorDimensions += listOf("environment", "market")
          productFlavors {
            create("uat") { dimension = "environment" }
            create("internal") { dimension = "market" }
          }
        }
        """
        try kotlin.write(to: app.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)
        XCTAssertEqual(FlavorDiscoveryService().android(project: root).map(\.name), ["uatinternal"])
    }

    func testPresetAndHistoryEncodeForPersistence() throws {
        let config = BuildConfiguration(projectID: "project", platform: .macOSApp, sdkVersion: "stable")
        let record = BuildHistoryRecord(id: UUID(), configuration: config, sdkLabel: "3.x", startedAt: Date(), endedAt: nil, status: .running, stage: .compiling, exitCode: nil, artifactPath: nil, exportedArtifactPath: nil, exportError: nil, log: "line", error: nil)
        let decoded = try JSONDecoder().decode(BuildHistoryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.configuration, config)
        XCTAssertEqual(decoded.log, "line")
    }

    // MARK: - iOS Flavor Discovery Regression Tests

    func testIOSDefaultRunnerOnlyProjectClassifiesRunnerAsOrdinaryScheme() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Profile", "Release"],
            schemes: [
                ("Runner", "Debug", "Release", "Profile")
            ]
        )
        let json = """
        {"workspace":{"name":"Runner","schemes":["Runner"]}}
        """
        let executor = MockExecutor([result(json)])
        let detector = IOSFlavorDetector(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        let diagnostics = await detector.discover(project: root, executor: executor)

        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty, "Filesystem discovery must not launch xcodebuild.")
        XCTAssertEqual(diagnostics.containerPath, "ios/Runner.xcworkspace")
        XCTAssertEqual(diagnostics.discoveredSchemes.count, 1)
        XCTAssertEqual(diagnostics.discoveredSchemes.first?.name, "Runner")
        XCTAssertEqual(diagnostics.discoveredSchemes.first?.confidence, .ordinaryScheme)
        XCTAssertTrue(diagnostics.flavors.isEmpty, "Default Runner-only project should not expose Runner as a --flavor.")
        XCTAssertNotNil(diagnostics.emptyStateExplanation)
        XCTAssertTrue(diagnostics.errors.isEmpty)
    }

    func testIOSMultipleSharedSchemesWithReleaseDevAndReleaseProduction() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: [
                "Debug", "Profile", "Release",
                "Debug-dev", "Profile-dev", "Release-dev",
                "Debug-staging", "Profile-staging", "Release-staging",
                "Debug-production", "Profile-production", "Release-production"
            ],
            schemes: [
                ("Runner", "Debug", "Release", "Profile"),
                ("dev", "Debug-dev", "Release-dev", "Profile-dev"),
                ("staging", "Debug-staging", "Release-staging", "Profile-staging"),
                ("production", "Debug-production", "Release-production", "Profile-production")
            ]
        )
        let json = """
        {"workspace":{"name":"Runner","schemes":["Runner","dev","staging","production","Pods-Runner","RunnerTests"]}}
        """
        let executor = MockExecutor([result(json)])
        let service = FlavorDiscoveryService(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        let diagnostics = await service.discoverIOS(project: root, executor: executor)

        XCTAssertEqual(Set(diagnostics.flavors.map(\.name)), Set(["dev", "staging", "production"]))
        XCTAssertTrue(diagnostics.flavors.allSatisfy { $0.confidence == .confirmedFlavor && $0.verified })
        XCTAssertTrue(diagnostics.discoveredBuildConfigurations.contains("Release-dev"))
        XCTAssertTrue(diagnostics.discoveredBuildConfigurations.contains("Release-production"))

        let podsScheme = diagnostics.discoveredSchemes.first { $0.name == "Pods-Runner" }
        XCTAssertNil(podsScheme, "Dependency schemes must not appear in application scheme diagnostics.")
        let testsScheme = diagnostics.discoveredSchemes.first { $0.name == "RunnerTests" }
        XCTAssertNil(testsScheme)
    }

    func testIOSSchemeUsesRenamedApplicationTargetAndExactArchiveConfigurationWithoutScanningWorkspaceSchemes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: "Client.xcworkspace",
            projectName: "Client.xcodeproj",
            applicationTargetName: "ClientApp",
            configurations: ["Debug", "Profile", "Release", "Debug-production", "Profile-production", "ArchiveProduction"],
            schemes: [("production", "Debug-production", "ArchiveProduction", "Profile-production")]
        )

        let workspaceSchemes = root.appendingPathComponent("ios/Client.xcworkspace/xcshareddata/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceSchemes, withIntermediateDirectories: true)
        let dependencyScheme = Self.schemeXML(launch: "Debug", archive: "Release", profile: "Profile")
            .replacingOccurrences(of: "BlueprintIdentifier = \"97C146ED1CF9000F007C117D\"", with: "BlueprintIdentifier = \"PODS_TARGET\"")
            .replacingOccurrences(of: "ReferencedContainer = \"container:Runner.xcodeproj\"", with: "ReferencedContainer = \"container:Pods.xcodeproj\"")
        try dependencyScheme.write(to: workspaceSchemes.appendingPathComponent("Pods-Client.xcscheme"), atomically: true, encoding: .utf8)
        let localSchemes = root.appendingPathComponent("ios/Client.xcodeproj/xcuserdata/alice.xcuserdatad/xcschemes", isDirectory: true)
        try FileManager.default.createDirectory(at: localSchemes, withIntermediateDirectories: true)
        let localScheme = Self.schemeXML(launch: "Debug-production", archive: "ArchiveProduction", profile: "Profile-production")
            .replacingOccurrences(of: "BlueprintIdentifier = \"97C146ED1CF9000F007C117D\"", with: "BlueprintIdentifier = \"RUNNER_TARGET\"")
            .replacingOccurrences(of: "ReferencedContainer = \"container:Runner.xcodeproj\"", with: "ReferencedContainer = \"container:Client.xcodeproj\"")
            .replacingOccurrences(of: "BlueprintName = \"Runner\"", with: "BlueprintName = \"ClientApp\"")
            .replacingOccurrences(of: "BuildableName = \"Runner.app\"", with: "BuildableName = \"ClientApp.app\"")
        try localScheme.write(to: localSchemes.appendingPathComponent("personal.xcscheme"), atomically: true, encoding: .utf8)

        let executor = MockExecutor([])
        let diagnostics = await IOSFlavorDetector(xcodebuildExecutable: URL(fileURLWithPath: "/usr/bin/xcodebuild"))
            .discover(project: root, executor: executor)

        XCTAssertEqual(diagnostics.flavors.map(\.name), ["production"])
        XCTAssertEqual(diagnostics.discoveredSchemes.map(\.name), ["production"])
        XCTAssertEqual(diagnostics.discoveredSchemes.first?.targetNames, ["ClientApp"])
        XCTAssertEqual(diagnostics.discoveredSchemes.first?.archiveConfiguration, "ArchiveProduction")
        XCTAssertEqual(diagnostics.localSchemes.count, 1)
        XCTAssertTrue(diagnostics.localSchemes[0].contains("Local to this Mac"))
        let measuredSeconds = try XCTUnwrap(diagnostics.discoveryDurationSeconds)
        XCTAssertLessThan(measuredSeconds, 1.0, "Filesystem-only scheme discovery should complete within one second for this fixture.")
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testIOSMalformedAndMissingArchiveSchemesAreDiagnosticsOnly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: nil,
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Profile", "Release", "Debug-dev", "Profile-dev", "Release-dev"],
            schemes: [("dev", "Debug-dev", "Release-dev", "Profile-dev")]
        )
        let schemes = root.appendingPathComponent("ios/Runner.xcodeproj/xcshareddata/xcschemes", isDirectory: true)
        try "<Scheme><invalid".write(to: schemes.appendingPathComponent("broken.xcscheme"), atomically: true, encoding: .utf8)
        let noArchive = Self.schemeXML(launch: "Debug", archive: "Release", profile: "Profile")
            .replacingOccurrences(of: #"<ArchiveAction[^>]*></ArchiveAction>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "BlueprintIdentifier = \"97C146ED1CF9000F007C117D\"", with: "BlueprintIdentifier = \"RUNNER_TARGET\"")
        try noArchive.write(to: schemes.appendingPathComponent("noArchive.xcscheme"), atomically: true, encoding: .utf8)

        let diagnostics = await IOSFlavorDetector().discover(project: root, executor: MockExecutor([]))
        XCTAssertEqual(diagnostics.flavors.map(\.name), ["dev"])
        XCTAssertEqual(diagnostics.discoveredSchemes.first(where: { $0.name == "broken" })?.confidence, .invalidConfiguration)
        XCTAssertEqual(diagnostics.discoveredSchemes.first(where: { $0.name == "noArchive" })?.confidence, .invalidConfiguration)
    }

    func testIOSDiscoverySupportsMultipleApplicationTargets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: nil,
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Profile", "Release"],
            schemes: [("Runner", "Debug", "Release", "Profile")]
        )
        let projectFile = root.appendingPathComponent("ios/Runner.xcodeproj/project.pbxproj")
        let data = try Data(contentsOf: projectFile)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        var objects = try XCTUnwrap(plist["objects"] as? [String: Any])
        objects["SECOND_APP_TARGET"] = [
            "isa": "PBXNativeTarget",
            "buildConfigurationList": "TARGET_CFG_LIST",
            "buildPhases": [String](),
            "buildRules": [String](),
            "dependencies": [String](),
            "name": "AdminApp",
            "productName": "AdminApp",
            "productType": "com.apple.product-type.application"
        ] as [String: Any]
        var rootProject = try XCTUnwrap(objects["ROOT_PROJECT"] as? [String: Any])
        rootProject["targets"] = ["RUNNER_TARGET", "SECOND_APP_TARGET"]
        objects["ROOT_PROJECT"] = rootProject
        plist["objects"] = objects
        let updatedProject = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updatedProject.write(to: projectFile)

        let schemes = projectFile.deletingLastPathComponent().appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        let adminScheme = Self.schemeXML(launch: "Debug", archive: "Release", profile: "Profile")
            .replacingOccurrences(of: "BlueprintIdentifier = \"97C146ED1CF9000F007C117D\"", with: "BlueprintIdentifier = \"SECOND_APP_TARGET\"")
            .replacingOccurrences(of: "BlueprintName = \"Runner\"", with: "BlueprintName = \"AdminApp\"")
            .replacingOccurrences(of: "BuildableName = \"Runner.app\"", with: "BuildableName = \"AdminApp.app\"")
        try adminScheme.write(to: schemes.appendingPathComponent("AdminApp.xcscheme"), atomically: true, encoding: .utf8)

        let diagnostics = await IOSFlavorDetector().discover(project: root, executor: MockExecutor([]))
        XCTAssertEqual(diagnostics.discoveredSchemes.first(where: { $0.name == "Runner" })?.targetNames, ["Runner"])
        XCTAssertEqual(diagnostics.discoveredSchemes.first(where: { $0.name == "AdminApp" })?.targetNames, ["AdminApp"])
    }

    func testIOSCustomWorkspaceAndCustomSchemeNamesPreserveCase() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: "WhiteLabelApp.xcworkspace",
            projectName: "WhiteLabelApp.xcodeproj",
            configurations: [
                "Debug", "Release", "Profile",
                "Debug-uat", "Release-uat", "Profile-uat",
                "Debug-production", "Release-production", "Profile-production"
            ],
            schemes: [
                ("AcmeUAT", "Debug-uat", "Release-uat", "Profile-uat"),
                ("AcmeProduction", "Debug-production", "Release-production", "Profile-production")
            ]
        )
        let json = """
        {"workspace":{"name":"WhiteLabelApp","schemes":["AcmeUAT","AcmeProduction"]}}
        """
        let executor = MockExecutor([result(json)])
        let detector = IOSFlavorDetector(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        let diagnostics = await detector.discover(project: root, executor: executor)

        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(diagnostics.containerPath, "ios/WhiteLabelApp.xcworkspace")
        XCTAssertEqual(Set(diagnostics.flavors.map(\.name)), Set(["AcmeUAT", "AcmeProduction"]))
        XCTAssertTrue(diagnostics.flavors.allSatisfy { $0.confidence == .confirmedFlavor })

        // Verify BuildConfiguration preserves exact case in --flavor
        var config = BuildConfiguration(projectID: root.path, platform: .iOSIPA, sdkVersion: "3.24.0")
        config.flavor = "AcmeUAT"
        let args = try config.arguments()
        XCTAssertTrue(args.contains("AcmeUAT"))
        XCTAssertFalse(args.contains("acmeuat"))
    }

    func testIOSSchemeAndBuildConfigurationMismatchProducesWarningsAndClassifications() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Setup:
        // 1. Scheme 'broken' references 'Release-nonexistent' which is missing from project.pbxproj -> .invalidConfiguration
        // 2. Scheme 'staging' uses plain 'Release' for Archive even though 'Release-staging' exists -> .potentialFlavor + warning
        // 3. 'Release-orphaned' exists in project.pbxproj with no scheme -> .invalidConfiguration + warning
        try createIOSProjectFixture(
            at: root,
            workspaceName: nil,
            projectName: "Runner.xcodeproj",
            configurations: [
                "Debug", "Release", "Profile",
                "Debug-staging", "Release-staging", "Profile-staging",
                "Debug-orphaned", "Release-orphaned"
            ],
            schemes: [
                ("Runner", "Debug", "Release", "Profile"),
                ("broken", "Debug", "Release-nonexistent", "Profile"),
                ("staging", "Debug-staging", "Release", "Profile-staging")
            ]
        )
        let json = """
        {"project":{"name":"Runner","schemes":["Runner","broken","staging"],"configurations":["Debug","Release","Profile","Debug-staging","Release-staging","Profile-staging","Debug-orphaned","Release-orphaned"],"targets":["Runner"]}}
        """
        let executor = MockExecutor([result(json)])
        let detector = IOSFlavorDetector(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        let diagnostics = await detector.discover(project: root, executor: executor)

        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)

        let brokenScheme = try XCTUnwrap(diagnostics.discoveredSchemes.first { $0.name == "broken" })
        XCTAssertEqual(brokenScheme.confidence, .invalidConfiguration)

        let stagingScheme = try XCTUnwrap(diagnostics.discoveredSchemes.first { $0.name == "staging" })
        XCTAssertEqual(stagingScheme.confidence, .potentialFlavor)

        let orphanedScheme = try XCTUnwrap(diagnostics.discoveredSchemes.first { $0.name == "orphaned" })
        XCTAssertEqual(orphanedScheme.confidence, .invalidConfiguration)

        // 'staging' is still exposed as a potential flavor with explanation, whereas 'broken' is not
        XCTAssertEqual(diagnostics.flavors.map(\.name), ["staging"])
        XCTAssertEqual(diagnostics.flavors.first?.confidence, .potentialFlavor)
        XCTAssertFalse(diagnostics.warnings.isEmpty)
        XCTAssertTrue(diagnostics.warnings.contains { $0.contains("Release-nonexistent") })
        XCTAssertTrue(diagnostics.warnings.contains { $0.contains("staging") })
        XCTAssertTrue(diagnostics.warnings.contains { $0.contains("orphaned") })
    }

    func testIOSDiscoveryDoesNotRequireXcodebuildWhenNoSharedSchemeExists() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Release", "Profile"],
            schemes: []
        )

        let missingXcode = root.appendingPathComponent("nonexistent-xcodebuild")
        let service = FlavorDiscoveryService(xcodebuildExecutable: missingXcode)
        let executor = MockExecutor([])

        let diagnostics = await service.discoverIOS(project: root, executor: executor)
        XCTAssertTrue(diagnostics.errors.isEmpty)
        XCTAssertTrue(diagnostics.flavors.isEmpty)
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testIOSMissingWorkspaceAndProjectReportsError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ios"), withIntermediateDirectories: true)

        let service = FlavorDiscoveryService(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        let executor = MockExecutor([])
        let diagnostics = await service.discoverIOS(project: root, executor: executor)

        XCTAssertFalse(diagnostics.errors.isEmpty)
        XCTAssertTrue(diagnostics.errors.first?.contains("No Xcode workspace") == true)
        do {
            _ = try await service.ios(project: root, executor: executor)
            XCTFail("Expected ios() to throw when workspace and project are missing.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Xcode workspace"))
        }
    }

    func testIOSInvalidXcodeProjectReportsCorruptedPBXProjAndWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wsDir = root.appendingPathComponent("ios/Runner.xcworkspace", isDirectory: true)
        let projDir = root.appendingPathComponent("ios/Runner.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try "<<<invalid xml".write(to: wsDir.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        try "<<<corrupted pbxproj".write(to: projDir.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let executor = MockExecutor([result("", code: 65, stderr: "xcodebuild: error: Unable to read project")])
        let service = FlavorDiscoveryService(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        let diagnostics = await service.discoverIOS(project: root, executor: executor)

        XCTAssertTrue(diagnostics.errors.contains { $0.contains("invalid or corrupted") })
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
        do {
            _ = try await service.ios(project: root, executor: executor)
            XCTFail("Expected invalid Xcode project to throw.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid or corrupted"))
        }
    }

    // MARK: - Dart Entrypoint Discovery Regression Tests

    func testDartEntrypointDiscoveryRecursiveSignaturesCommentsUnicodeAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let externalDir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: externalDir) }

        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let bootstrap = lib.appendingPathComponent("bootstrap", isDirectory: true)
        let configDir = lib.appendingPathComponent("config", isDirectory: true)
        let unicodeDir = lib.appendingPathComponent("प्रारंभ モジュール café", isDirectory: true)
        let hiddenGenDir = lib.appendingPathComponent(".dart_tool", isDirectory: true)
        let buildDir = lib.appendingPathComponent("build", isDirectory: true)

        for dir in [lib, bootstrap, configDir, unicodeDir, hiddenGenDir, buildDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 1. Root lib/main.dart
        try "void main() {\n  runApp(const MyApp());\n}\n".write(
            to: lib.appendingPathComponent("main.dart"), atomically: true, encoding: .utf8
        )
        // 2. Multiple main_*.dart files with async / Future<void> / FutureOr<void> / parameters
        try "Future<void> main() async {\n  await init();\n}\n".write(
            to: lib.appendingPathComponent("main_dev.dart"), atomically: true, encoding: .utf8
        )
        try "import 'dart:async';\nFutureOr<void> main(List<String> args) async => runApp(App());\n".write(
            to: lib.appendingPathComponent("main_staging.dart"), atomically: true, encoding: .utf8
        )
        // 3. Nested entrypoints
        try "@pragma('vm:entry-point')\nvoid main(List<String> arguments) {\n}\n".write(
            to: bootstrap.appendingPathComponent("main_uat.dart"), atomically: true, encoding: .utf8
        )
        try "Future main() async {\n}\n".write(
            to: configDir.appendingPathComponent("main_production.dart"), atomically: true, encoding: .utf8
        )
        // 4. Unicode + spaces path
        try "void main() {}\n".write(
            to: unicodeDir.appendingPathComponent("app_entry.dart"), atomically: true, encoding: .utf8
        )
        // 5. Commented-out main functions & main inside string literal -> should be ignored
        let commentedSource = """
        // void main() {}
        /*
         Future<void> main() async {}
         /* nestedFutureOr<void> main() {} */
        */
        const example = "void main() {}";
        const multiline = '''
        void main(List<String> args) {}
        ''';
        """
        try commentedSource.write(
            to: lib.appendingPathComponent("main_commented_out.dart"), atomically: true, encoding: .utf8
        )
        // 6. Dart file without top-level main (e.g. class method named main) -> should be ignored
        let classMethodSource = """
        class Runner {
          void main() {}
        }
        void helper() {}
        """
        try classMethodSource.write(
            to: lib.appendingPathComponent("main_class_only.dart"), atomically: true, encoding: .utf8
        )
        // 7. Excluded directories (.dart_tool, build) -> should be ignored
        try "void main() {}".write(to: hiddenGenDir.appendingPathComponent("ignored_main.dart"), atomically: true, encoding: .utf8)
        try "void main() {}".write(to: buildDir.appendingPathComponent("ignored_build_main.dart"), atomically: true, encoding: .utf8)

        // 8. Symlinks (both file and directory) escaping project root -> should be skipped with warning
        let externalFile = externalDir.appendingPathComponent("outside_main.dart")
        try "void main() {}".write(to: externalFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: lib.appendingPathComponent("escaped_symlink.dart"),
            withDestinationURL: externalFile
        )
        try FileManager.default.createSymbolicLink(
            at: lib.appendingPathComponent("escaped_dir_symlink"),
            withDestinationURL: externalDir
        )

        let detector = DartEntrypointDetector()
        let result = detector.discoverWithDiagnostics(project: root)
        let paths = result.entrypoints.map(\.path)

        XCTAssertEqual(paths.first, "lib/main.dart")
        XCTAssertTrue(paths.contains("lib/main_dev.dart"))
        XCTAssertTrue(paths.contains("lib/main_staging.dart"))
        XCTAssertTrue(paths.contains("lib/bootstrap/main_uat.dart"))
        XCTAssertTrue(paths.contains("lib/config/main_production.dart"))
        XCTAssertTrue(paths.contains("lib/प्रारंभ モジュール café/app_entry.dart"))

        XCTAssertFalse(paths.contains("lib/main_commented_out.dart"))
        XCTAssertFalse(paths.contains("lib/main_class_only.dart"))
        XCTAssertFalse(paths.contains { $0.contains("ignored") })
        XCTAssertFalse(paths.contains { $0.contains("escaped_symlink") })
        XCTAssertTrue(result.warnings.contains { $0.contains("escaped_symlink.dart") })
    }

    func testDartEntrypointDiscoveryMarksAmbiguousSyntaxAsPotentialAndHandlesMissingLib() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Missing lib directory
        let missingLibResult = DartEntrypointDetector().discoverWithDiagnostics(project: root)
        XCTAssertTrue(missingLibResult.entrypoints.isEmpty)
        XCTAssertFalse(missingLibResult.errors.isEmpty)

        // Create lib with ambiguous/unbalanced syntax containing main(
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try "void main() { if (true) {".write(to: lib.appendingPathComponent("main_broken.dart"), atomically: true, encoding: .utf8)

        let result = DartEntrypointDetector().discoverWithDiagnostics(project: root)
        XCTAssertEqual(result.entrypoints.count, 1)
        XCTAssertEqual(result.entrypoints.first?.path, "lib/main_broken.dart")
        XCTAssertEqual(result.entrypoints.first?.confidence, .potential)
    }

    // MARK: - Automatic Mapping, ViewModel, Caching & Concurrency Regression Tests

    func testFlavorEntrypointMapperMatchesNestedPathsAliasesAndManualOverrides() {
        let entrypoints = [
            "lib/main.dart",
            "lib/main_dev.dart",
            "lib/main_staging.dart",
            "lib/bootstrap/main_uat.dart",
            "lib/config/main_production.dart"
        ]

        // Exact matches (root and nested)
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "dev", entrypoints: entrypoints), "lib/main_dev.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "staging", entrypoints: entrypoints), "lib/main_staging.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "uat", entrypoints: entrypoints), "lib/bootstrap/main_uat.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "production", entrypoints: entrypoints), "lib/config/main_production.dart")

        // Alias matches
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "prod", entrypoints: entrypoints), "lib/config/main_production.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "development", entrypoints: entrypoints), "lib/main_dev.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "stg", entrypoints: entrypoints), "lib/main_staging.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "uatBlue", entrypoints: entrypoints), "lib/bootstrap/main_uat.dart")

        // Fallback to lib/main.dart
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: nil, entrypoints: entrypoints), "lib/main.dart")
        XCTAssertEqual(FlavorEntrypointMapper.resolveEntrypoint(for: "unknownFlavor", entrypoints: entrypoints), "lib/main.dart")

        // Manual override takes highest priority
        XCTAssertEqual(
            FlavorEntrypointMapper.resolveEntrypoint(
                for: "dev",
                entrypoints: entrypoints,
                manualMapping: "lib/bootstrap/main_uat.dart",
                savedSelection: "lib/main_dev.dart"
            ),
            "lib/bootstrap/main_uat.dart"
        )
    }

    @MainActor
    func testViewModelPreservesManualOverridesAndHandlesPlatformAndFlavorSwitching() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create Dart entrypoints
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let bootstrap = lib.appendingPathComponent("bootstrap", isDirectory: true)
        let configDir = lib.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        for file in [
            lib.appendingPathComponent("main.dart"),
            lib.appendingPathComponent("main_dev.dart"),
            lib.appendingPathComponent("main_staging.dart"),
            bootstrap.appendingPathComponent("main_uat.dart"),
            configDir.appendingPathComponent("main_production.dart")
        ] {
            try "void main() {}".write(to: file, atomically: true, encoding: .utf8)
        }

        // Create Android flavors: dev, staging
        let androidApp = root.appendingPathComponent("android/app", isDirectory: true)
        try FileManager.default.createDirectory(at: androidApp, withIntermediateDirectories: true)
        let gradle = """
        android {
          flavorDimensions "env"
          productFlavors {
            dev { dimension "env" }
            staging { dimension "env" }
          }
        }
        """
        try gradle.write(to: androidApp.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)

        // Create iOS flavors: uat, production
        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: [
                "Debug", "Release", "Profile",
                "Debug-uat", "Release-uat", "Profile-uat",
                "Debug-production", "Release-production", "Profile-production"
            ],
            schemes: [
                ("Runner", "Debug", "Release", "Profile"),
                ("uat", "Debug-uat", "Release-uat", "Profile-uat"),
                ("production", "Debug-production", "Release-production", "Profile-production")
            ]
        )
        let iosJSON = """
        {"workspace":{"name":"Runner","schemes":["Runner","uat","production"]}}
        """

        let suite = "BuildReleaseViewModelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildReleaseStore(defaults: defaults)
        let executor = MockExecutor([result(iosJSON), result(iosJSON)])
        let project = FlutterProject(path: root.path, name: "fixture", version: "3.24.0")
        let vm = BuildReleaseViewModel(
            project: project,
            sdkVersion: "3.24.0",
            executor: executor,
            store: store,
            defaults: defaults,
            flavorDiscoveryService: FlavorDiscoveryService(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        )

        // 1. Initial Android discovery
        await vm.refreshDiscovery(force: true)
        XCTAssertEqual(vm.flavors.map(\.name), ["dev", "staging"])
        XCTAssertEqual(vm.configuration.flavor, "dev")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/main_dev.dart")

        // 2. User manually overrides entrypoint for Android 'dev' to 'lib/main.dart'
        vm.selectEntrypoint("lib/main.dart", isManual: true)
        XCTAssertEqual(vm.configuration.entrypoint, "lib/main.dart")

        // 3. Switch flavor to 'staging' -> suggests 'lib/main_staging.dart'
        vm.selectFlavor("staging")
        XCTAssertEqual(vm.configuration.flavor, "staging")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/main_staging.dart")

        // 4. Switch back to 'dev' -> restores manual override 'lib/main.dart'!
        vm.selectFlavor("dev")
        XCTAssertEqual(vm.configuration.flavor, "dev")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/main.dart")

        // 5. Switch platform from Android to iOS -> discovers iOS flavors ['uat', 'production'], keeps entrypoints populated, selects 'uat' -> 'lib/bootstrap/main_uat.dart'
        await vm.selectPlatform(.iOSIPA)
        XCTAssertEqual(vm.entrypoints.count, 5, "Switching platforms must not clear entrypoints.")
        XCTAssertEqual(vm.flavors.map(\.name), ["production", "uat"])
        XCTAssertEqual(vm.configuration.flavor, "production")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/config/main_production.dart")
        XCTAssertEqual(try vm.configuration.arguments(), ["build", "ipa", "--release", "-t", "lib/config/main_production.dart", "--flavor", "production", "--tree-shake-icons"])

        // 6. Switch iOS flavor to 'production' -> suggests 'lib/config/main_production.dart'
        vm.selectFlavor("production")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/config/main_production.dart")
        XCTAssertEqual(try vm.configuration.arguments(), ["build", "ipa", "--release", "-t", "lib/config/main_production.dart", "--flavor", "production", "--tree-shake-icons"])

        // 7. Switch back to Android -> restores Android's 'dev' flavor and its manual entrypoint 'lib/main.dart'
        await vm.selectPlatform(.androidAPK)
        XCTAssertEqual(vm.configuration.flavor, "dev")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/main.dart")
    }

    @MainActor
    func testCacheInvalidationOnFileChangeAndNonCachingOfFailures() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try "void main() {}".write(to: lib.appendingPathComponent("main.dart"), atomically: true, encoding: .utf8)

        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Release", "Profile", "Debug-dev", "Release-dev", "Profile-dev"],
            schemes: [("dev", "Debug-dev", "Release-dev", "Profile-dev")]
        )

        let cache = BuildDiscoveryCache()
        // The filesystem path succeeds without invoking xcodebuild.
        let failingExecutor = MockExecutor([])
        let suite = "BuildReleaseCacheTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildReleaseStore(defaults: defaults)
        let project = FlutterProject(path: root.path, name: "fixture", version: "3.24.0")
        let vm = BuildReleaseViewModel(
            project: project,
            sdkVersion: "3.24.0",
            executor: failingExecutor,
            store: store,
            defaults: defaults,
            cache: cache,
            flavorDiscoveryService: FlavorDiscoveryService(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        )
        vm.configuration.platform = .iOSIPA

        // 1. First discovery reads the app project and shared schemes from disk.
        await vm.refreshDiscovery(force: false)
        XCTAssertNil(vm.discoveryError)

        // 2. Subsequent non-forced call uses the cache.
        await vm.refreshDiscovery(force: false)
        XCTAssertNil(vm.discoveryError)
        XCTAssertEqual(vm.flavors.map(\.name), ["dev"])
        let callsAfterSecond = await failingExecutor.calls.count
        XCTAssertEqual(callsAfterSecond, 0)

        // 3. Calling refreshDiscovery(force: false) again without file changes uses cache (no new executor call!)
        await vm.refreshDiscovery(force: false)
        let callsAfterCached = await failingExecutor.calls.count
        XCTAssertEqual(callsAfterCached, 0)

        // 4. Modify lib/ by adding a new entrypoint and ios/ by adding a new .xcscheme -> cache invalidates automatically!
        try "void main() {}".write(to: lib.appendingPathComponent("main_staging.dart"), atomically: true, encoding: .utf8)
        let schemesDir = root.appendingPathComponent("ios/Runner.xcodeproj/xcshareddata/xcschemes", isDirectory: true)
        try Self.schemeXML(launch: "Debug-dev", archive: "Release-dev", profile: "Profile-dev")
            .replacingOccurrences(of: "BlueprintIdentifier = \"97C146ED1CF9000F007C117D\"", with: "BlueprintIdentifier = \"RUNNER_TARGET\"")
            .write(to: schemesDir.appendingPathComponent("staging.xcscheme"), atomically: true, encoding: .utf8)

        await vm.refreshDiscovery(force: false)
        let callsAfterFileChange = await failingExecutor.calls.count
        XCTAssertEqual(callsAfterFileChange, 0)
        XCTAssertTrue(vm.entrypoints.contains("lib/main_staging.dart"))
        XCTAssertEqual(vm.flavors.map(\.name), ["dev", "staging"])
    }

    func testConcurrentFlavorDiscoveryForSameProjectIsCoalesced() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = BuildDiscoveryCache()
        let counter = DiscoveryInvocationCounter()
        let diagnostics = FlavorDiscoveryDiagnostics(
            platform: .iOSIPA,
            discoveredSchemes: [DiscoveredXcodeScheme(name: "prod", confidence: .confirmedFlavor)]
        )

        let first = Task {
            await cache.discoverFlavors(for: root, platform: .iOSIPA, force: true) {
                await counter.increment()
                try? await Task.sleep(for: .milliseconds(80))
                return diagnostics
            }
        }
        await counter.waitForFirstInvocation()
        let second = Task {
            await cache.discoverFlavors(for: root, platform: .iOSIPA, force: true) {
                await counter.increment()
                return diagnostics
            }
        }

        let firstResult = await first.value
        let secondResult = await second.value
        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(firstResult, diagnostics)
        XCTAssertEqual(secondResult, diagnostics)
    }

    @MainActor
    func testStaleAsyncDiscoveryResultsDoNotOverwriteNewerPlatformSelection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let androidApp = root.appendingPathComponent("android/app", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: androidApp, withIntermediateDirectories: true)
        try "void main() {}".write(to: lib.appendingPathComponent("main.dart"), atomically: true, encoding: .utf8)
        try """
        android {
          productFlavors {
            androidOnly {}
          }
        }
        """.write(to: androidApp.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)

        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: ["Debug", "Release", "Profile", "Debug-iosOnly", "Release-iosOnly", "Profile-iosOnly"],
            schemes: [("iosOnly", "Debug-iosOnly", "Release-iosOnly", "Profile-iosOnly")]
        )

        // Slow executor for iOS
        let slowIOSExecutor = MockExecutor(
            [result(#"{"workspace":{"name":"Runner","schemes":["iosOnly"]}}"#)],
            delay: .milliseconds(250)
        )
        let suite = "BuildReleaseStaleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildReleaseStore(defaults: defaults)
        let project = FlutterProject(path: root.path, name: "fixture", version: "3.24.0")
        let vm = BuildReleaseViewModel(
            project: project,
            sdkVersion: "3.24.0",
            executor: slowIOSExecutor,
            store: store,
            defaults: defaults,
            flavorDiscoveryService: FlavorDiscoveryService(xcodebuildExecutable: URL(fileURLWithPath: "/bin/sh"))
        )

        // Start switching to iOS (slow) and before it finishes, switch to Android (fast)
        let staleTask = Task {
            await vm.selectPlatform(.iOSIPA)
        }
        try await Task.sleep(for: .milliseconds(40))
        await vm.selectPlatform(.androidAPK)
        await staleTask.value

        XCTAssertEqual(vm.configuration.platform, .androidAPK)
        XCTAssertEqual(vm.flavors.map(\.name), ["androidOnly"], "Stale iOS discovery result must not overwrite newer Android state.")
    }

    @MainActor
    func testRealXcodebuildIntegrationWithFlutterProjectStructure() async throws {
        let xcodebuild = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: xcodebuild.path), "xcodebuild is required for live integration test")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "name: live_flutter_project\n".write(to: root.appendingPathComponent("pubspec.yaml"), atomically: true, encoding: .utf8)

        let lib = root.appendingPathComponent("lib", isDirectory: true)
        let bootstrap = lib.appendingPathComponent("bootstrap", isDirectory: true)
        try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: true)
        try "void main() {}".write(to: lib.appendingPathComponent("main.dart"), atomically: true, encoding: .utf8)
        try "Future<void> main() async {}".write(to: lib.appendingPathComponent("main_dev.dart"), atomically: true, encoding: .utf8)
        try "void main(List<String> args) {}".write(to: bootstrap.appendingPathComponent("main_uat.dart"), atomically: true, encoding: .utf8)

        try createIOSProjectFixture(
            at: root,
            workspaceName: "Runner.xcworkspace",
            projectName: "Runner.xcodeproj",
            configurations: [
                "Debug", "Profile", "Release",
                "Debug-dev", "Profile-dev", "Release-dev",
                "Debug-uat", "Profile-uat", "Release-uat"
            ],
            schemes: [
                ("Runner", "Debug", "Release", "Profile"),
                ("dev", "Debug-dev", "Release-dev", "Profile-dev"),
                ("uat", "Debug-uat", "Release-uat", "Profile-uat")
            ]
        )

        let suite = "BuildReleaseLiveIntegration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuildReleaseStore(defaults: defaults)
        let project = FlutterProject(path: root.path, name: "live_flutter_project", version: "3.24.0")
        let vm = BuildReleaseViewModel(
            project: project,
            sdkVersion: "3.24.0",
            executor: CLIExecutor(),
            store: store,
            defaults: defaults,
            flavorDiscoveryService: FlavorDiscoveryService(xcodebuildExecutable: xcodebuild)
        )
        vm.configuration.platform = .iOSIPA

        await vm.refreshDiscovery(force: true)

        XCTAssertNil(vm.discoveryError)
        XCTAssertEqual(vm.diagnostics.containerPath, "ios/Runner.xcworkspace")
        XCTAssertEqual(Set(vm.flavors.map(\.name)), Set(["dev", "uat"]))
        XCTAssertTrue(vm.flavors.allSatisfy { $0.confidence == .confirmedFlavor && $0.verified })
        XCTAssertEqual(vm.entrypoints, ["lib/main.dart", "lib/bootstrap/main_uat.dart", "lib/main_dev.dart"])

        vm.selectFlavor("uat")
        XCTAssertEqual(vm.configuration.entrypoint, "lib/bootstrap/main_uat.dart")
        XCTAssertEqual(
            try vm.configuration.arguments(),
            ["build", "ipa", "--release", "-t", "lib/bootstrap/main_uat.dart", "--flavor", "uat", "--tree-shake-icons"]
        )
    }

    // MARK: - Fixture Helpers

    private func createIOSProjectFixture(
        at root: URL,
        workspaceName: String?,
        projectName: String,
        applicationTargetName: String = "Runner",
        configurations: [String],
        schemes: [(name: String, launch: String, archive: String, profile: String)]
    ) throws {
        let fm = FileManager.default
        let iosDir = root.appendingPathComponent("ios", isDirectory: true)
        try fm.createDirectory(at: iosDir, withIntermediateDirectories: true)

        if let workspaceName {
            let wsDir = iosDir.appendingPathComponent(workspaceName, isDirectory: true)
            try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
            let wsXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0">
               <FileRef location = "group:\(projectName)"></FileRef>
            </Workspace>
            """
            try wsXML.write(to: wsDir.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        }

        let projDir = iosDir.appendingPathComponent(projectName, isDirectory: true)
        let schemesDir = projDir.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        try fm.createDirectory(at: schemesDir, withIntermediateDirectories: true)

        var projConfigIDs: [String] = []
        var targetConfigIDs: [String] = []
        var objectsDict: [String: Any] = [
            "MAIN_GROUP": [
                "isa": "PBXGroup",
                "children": [String](),
                "sourceTree": "<group>"
            ],
            "RUNNER_TARGET": [
                "isa": "PBXNativeTarget",
                "buildConfigurationList": "TARGET_CFG_LIST",
                "buildPhases": [String](),
                "buildRules": [String](),
                "dependencies": [String](),
                "name": applicationTargetName,
                "productName": applicationTargetName,
                "productType": "com.apple.product-type.application"
            ]
        ]
        for (idx, cfg) in configurations.enumerated() {
            let pID = "PCFG_\(idx)"
            let tID = "TCFG_\(idx)"
            projConfigIDs.append(pID)
            targetConfigIDs.append(tID)
            objectsDict[pID] = [
                "isa": "XCBuildConfiguration",
                "buildSettings": [String: String](),
                "name": cfg
            ]
            objectsDict[tID] = [
                "isa": "XCBuildConfiguration",
                "buildSettings": [String: String](),
                "name": cfg
            ]
        }
        objectsDict["PROJ_CFG_LIST"] = [
            "isa": "XCConfigurationList",
            "buildConfigurations": projConfigIDs,
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": configurations.first ?? "Release"
        ]
        objectsDict["TARGET_CFG_LIST"] = [
            "isa": "XCConfigurationList",
            "buildConfigurations": targetConfigIDs,
            "defaultConfigurationIsVisible": "0",
            "defaultConfigurationName": configurations.first ?? "Release"
        ]
        objectsDict["ROOT_PROJECT"] = [
            "isa": "PBXProject",
            "buildConfigurationList": "PROJ_CFG_LIST",
            "compatibilityVersion": "Xcode 14.0",
            "mainGroup": "MAIN_GROUP",
            "projectDirPath": "",
            "projectRoot": "",
            "targets": ["RUNNER_TARGET"]
        ]
        let pbxprojPlist: [String: Any] = [
            "archiveVersion": "1",
            "classes": [String: String](),
            "objectVersion": "56",
            "rootObject": "ROOT_PROJECT",
            "objects": objectsDict
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: pbxprojPlist, format: .xml, options: 0)
        try plistData.write(to: projDir.appendingPathComponent("project.pbxproj"))

        for scheme in schemes {
            let xml = Self.schemeXML(launch: scheme.launch, archive: scheme.archive, profile: scheme.profile)
                .replacingOccurrences(of: "BlueprintIdentifier = \"97C146ED1CF9000F007C117D\"", with: "BlueprintIdentifier = \"RUNNER_TARGET\"")
                .replacingOccurrences(of: "ReferencedContainer = \"container:Runner.xcodeproj\"", with: "ReferencedContainer = \"container:\(projectName)\"")
                .replacingOccurrences(of: "BlueprintName = \"Runner\"", with: "BlueprintName = \"\(applicationTargetName)\"")
                .replacingOccurrences(of: "BuildableName = \"Runner.app\"", with: "BuildableName = \"\(applicationTargetName).app\"")
            try xml.write(to: schemesDir.appendingPathComponent("\(scheme.name).xcscheme"), atomically: true, encoding: .utf8)
        }
    }

    private static func schemeXML(launch: String, archive: String, profile: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "1510" version = "1.7">
           <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
              <BuildActionEntries>
                 <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintIdentifier = "97C146ED1CF9000F007C117D"
                       BuildableName = "Runner.app"
                       BlueprintName = "Runner"
                       ReferencedContainer = "container:Runner.xcodeproj">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction buildConfiguration = "\(launch)"></TestAction>
           <LaunchAction buildConfiguration = "\(launch)"></LaunchAction>
           <ProfileAction buildConfiguration = "\(profile)"></ProfileAction>
           <AnalyzeAction buildConfiguration = "\(launch)"></AnalyzeAction>
           <ArchiveAction buildConfiguration = "\(archive)" revealArchiveInOrganizer = "YES"></ArchiveAction>
        </Scheme>
        """
    }
}

private actor DiscoveryInvocationCounter {
    private(set) var value = 0
    private var firstInvocation: CheckedContinuation<Void, Never>?

    func increment() {
        value += 1
        firstInvocation?.resume()
        firstInvocation = nil
    }

    func waitForFirstInvocation() async {
        guard value == 0 else { return }
        await withCheckedContinuation { firstInvocation = $0 }
    }
}

private actor RecordingBuildExecutor: CLIExecuting {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if arguments.contains("-h") {
            let target = arguments.dropFirst().first ?? "ipa"
            let help = """
            Usage: flutter build \(target) [arguments]
              --[no-]tree-shake-icons    Tree shake icons.
              --split-debug-info=<v1.2.3/>  Directory for symbols.
              --[no-]obfuscate            Obfuscate code.
            """
            return CLIResult(exitCode: 0, stdout: help, stderr: "")
        }
        return CLIResult(exitCode: 0, stdout: "build complete", stderr: "")
    }
}

private actor ArchivePipelineExecutor: CLIExecuting {
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        if arguments.contains("-h") {
            let target = arguments.dropFirst().first ?? "apk"
            return CLIResult(exitCode: 0, stdout: """
            Usage: flutter build \(target) [arguments]
              --release
              --[no-]obfuscate
              --split-debug-info=<v1.2.3/>
              --[no-]tree-shake-icons
              --dart-define=<key=value>
            """, stderr: "")
        }
        guard let directory else { return CLIResult(exitCode: 2, stdout: "", stderr: "missing project directory") }
        if let index = arguments.firstIndex(of: "--split-debug-info"), arguments.indices.contains(index + 1) {
            let symbolDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: symbolDirectory, withIntermediateDirectories: true)
            try Data("symbols".utf8).write(to: symbolDirectory.appendingPathComponent("app.android-arm64.symbols"))
        }
        let artifact = directory.appendingPathComponent("build/app/outputs/flutter-apk/app-release.apk")
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("apk".utf8).write(to: artifact)
        await output?(CLIOutput(text: "Built build/app/outputs/flutter-apk/app-release.apk\n", isError: false))
        return CLIResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct StaticCapabilityExecutor: CLIExecuting {
    let response: CLIResult

    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        response
    }
}

private struct IncrementalBuildExecutor: CLIExecuting {
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        if arguments.contains("--help") { return CLIResult(exitCode: 0, stdout: "--release --tree-shake-icons", stderr: "") }
        await output?(CLIOutput(text: "incremental stdout\r", isError: false))
        await output?(CLIOutput(text: "incremental stderr\n", isError: true))
        try await Task.sleep(for: .milliseconds(500))
        return CLIResult(exitCode: 1, stdout: "", stderr: "fixture failure")
    }
}
