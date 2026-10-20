import XCTest
@testable import fvm_gui

final class FlutterDoctorTests: XCTestCase {
    func testRepresentativeDoctorOutputParsesWarningsMultilineMessagesAndSuggestedFixes() throws {
        let output = try fixture("flutter-doctor-verbose.txt")
        let parsed = try FlutterDoctorParser().parse(output)

        XCTAssertTrue(parsed.formatRecognized)
        XCTAssertEqual(parsed.overallStatus, .warning)
        XCTAssertEqual(parsed.categories.map(\.name), ["Flutter SDK", "Android Toolchain", "Xcode", "Network Resources"])
        XCTAssertEqual(parsed.categories.map(\.status), [.passed, .warning, .passed, .passed])
        let android = try XCTUnwrap(parsed.categories.first { $0.identifier.hasPrefix("android-toolchain") })
        XCTAssertTrue(android.diagnosticMessages.contains("Run `flutter doctor --android-licenses` to accept the SDK licenses."))
        XCTAssertTrue(android.suggestedActions.contains { $0.id == "android-licenses" })
        XCTAssertTrue(android.rawOutput.contains("Android SDK version 35.0.0"))
    }

    func testANSIOutputAndSuccessfulSummaryAreParsedWithoutInventingAbsentCategories() throws {
        let output = "\u{001B}[32m[✓]\u{001B}[0m Flutter (stable)\n    • Flutter at /sdk\n[✓] Network resources\n    • All expected network hosts are available.\n• No issues found!\n"
        let parsed = try FlutterDoctorParser().parse(output)
        XCTAssertEqual(parsed.overallStatus, .passed)
        XCTAssertEqual(parsed.categories.map(\.name), ["Flutter SDK", "Network Resources"])
        XCTAssertTrue(parsed.categories.allSatisfy { !$0.rawOutput.contains("\u{001B}") })

        let partial = try FlutterDoctorParser().parse("[✓] Flutter (stable)\n")
        XCTAssertEqual(partial.categories.count, 1)
        XCTAssertEqual(partial.overallStatus, .unknown, "A success marker without Doctor's completion summary is not a complete pass")
    }

    func testFailedUnknownAndUnrecognizedOutputRemainConservative() throws {
        let failed = try FlutterDoctorParser().parse("[✗] Android toolchain\n    ✗ Android SDK not found.\n! Doctor found issues in 1 category.\n")
        XCTAssertEqual(failed.overallStatus, .failed)
        XCTAssertEqual(failed.categories.first?.status, .failed)
        XCTAssertTrue(failed.categories.first?.suggestedActions.contains { $0.id == "android-sdk" } == true)

        let unknownMarker = try FlutterDoctorParser().parse("[?] New platform diagnostic\n    Details unavailable.\n")
        XCTAssertEqual(unknownMarker.categories.first?.status, .unknown)
        XCTAssertEqual(unknownMarker.overallStatus, .unknown)

        let unknownFormat = try FlutterDoctorParser().parse("doctor output changed unexpectedly\nNo structured categories here\n")
        XCTAssertFalse(unknownFormat.formatRecognized)
        XCTAssertEqual(unknownFormat.overallStatus, .unknown)
        XCTAssertTrue(unknownFormat.message?.contains("raw output") == true)
    }

    func testXcodeAndroidStudioAndCocoaPodsSuggestedActionsAreTargeted() throws {
        let output = """
        [!] Xcode - develop for iOS and macOS
            xcode-select: error: command line tools are not installed
            CocoaPods not installed.
        [!] Android Studio (not installed)
            Android Studio not available.
        ! Doctor found issues in 2 categories.
        """
        let parsed = try FlutterDoctorParser().parse(output)
        let xcode = try XCTUnwrap(parsed.categories.first { $0.identifier.hasPrefix("xcode") })
        XCTAssertTrue(xcode.suggestedActions.contains { $0.id == "xcode-cli-tools" })
        XCTAssertTrue(xcode.suggestedActions.contains { $0.id == "cocoapods" })
        let studio = try XCTUnwrap(parsed.categories.first { $0.identifier.hasPrefix("android-studio") })
        XCTAssertTrue(studio.suggestedActions.contains { $0.id == "android-studio" })
    }

    func testOversizedOutputReportsParserFailure() throws {
        XCTAssertThrowsError(try FlutterDoctorParser().parse(String(repeating: "x", count: 10_000_001)))
    }

    @MainActor func testProjectDashboardDoctorUsesProjectEffectiveSDKAndWorkingDirectory() async throws {
        let output = "[✓] Flutter (3.24.1)\n• No issues found!\n"
        let fvm = DoctorTestFVM(behavior: .result(result(output)))
        let activity = ActivityStore()
        let model = FlutterDoctorViewModel(service: FlutterDoctorService(), activity: activity)
        await model.configure(fvm: fvm)
        let project = FlutterProject(path: "/tmp/sample project", name: "sample", version: "3.24.1", type: .flutterApp)
        let sdk = makeSDK("3.24.1", path: "/fvm/versions/3.24.1")
        let global = makeSDK("stable", path: "/fvm/versions/stable", global: true)

        model.runProject(project, installedSDKs: [global, sdk])
        for _ in 0..<100 where model.isRunning { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(model.report?.sdkName, sdk.name)
        XCTAssertEqual(model.report?.projectPath, URL(fileURLWithPath: project.path).standardizedFileURL.path)
        let invocation = await fvm.lastInvocation
        XCTAssertEqual(invocation?.sdkDirectory, sdk.directory)
        XCTAssertEqual(invocation?.directory?.path, project.path)
        XCTAssertEqual(invocation?.timeout, FlutterDoctorService.timeout)
    }

    @MainActor func testGlobalInspectionUsesSelectedSDKWithoutProjectDirectory() async throws {
        let fvm = DoctorTestFVM(behavior: .result(result("[✓] Flutter (3.24.1)\n• No issues found!")))
        let activity = ActivityStore()
        let service = FlutterDoctorService(fvm: fvm)
        let sdk = makeSDK("3.24.1", path: "/fvm/versions/3.24.1")
        let report = await service.inspect(sdk: sdk, project: nil, operationID: UUID(), activity: activity)
        let invocation = await fvm.lastInvocation
        XCTAssertEqual(report.overallStatus, .passed)
        XCTAssertEqual(invocation?.sdkDirectory, sdk.directory)
        XCTAssertNil(invocation?.directory)
    }

    @MainActor func testMissingSDKIsFailedAndNeverReportedAsPassing() async {
        let activity = ActivityStore()
        let report = await FlutterDoctorService().inspect(sdk: nil, project: nil, operationID: UUID(), activity: activity)
        XCTAssertEqual(report.overallStatus, .failed)
        XCTAssertEqual(report.categories.first?.identifier, "flutter-sdk")
        XCTAssertFalse(report.categories.first?.suggestedActions.isEmpty ?? true)
        XCTAssertEqual(activity.entries.first?.operationStatus, .failed)
    }

    @MainActor func testCancellationAndTimeoutPreservePartialOutputAndStatus() async throws {
        let sdk = makeSDK("3.24.1", path: "/fvm/versions/3.24.1")
        let partial = "[✓] Flutter (3.24.1)\n"
        let activity = ActivityStore()
        let delayedFVM = DoctorTestFVM(behavior: .delay(.seconds(5), result(partial)))
        let service = FlutterDoctorService(fvm: delayedFVM)
        let cancelID = UUID()
        let task = Task { await service.inspect(sdk: sdk, project: nil, operationID: cancelID, activity: activity) }
        for _ in 0..<100 where !activity.entries.contains(where: { $0.id == cancelID }) { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.executionStatus, .cancelled)
        XCTAssertEqual(cancelled.overallStatus, .unknown)
        XCTAssertTrue(cancelled.rawOutput.contains("Flutter (3.24.1)"))
        XCTAssertEqual(activity.entries.first(where: { $0.id == cancelID })?.operationStatus, .cancelled)

        let timeoutFVM = DoctorTestFVM(behavior: .timeout(partial))
        let timeoutActivity = ActivityStore()
        let timedOut = await FlutterDoctorService(fvm: timeoutFVM).inspect(sdk: sdk, project: nil,
                                                                           operationID: UUID(), activity: timeoutActivity)
        XCTAssertEqual(timedOut.executionStatus, .failed)
        XCTAssertEqual(timedOut.overallStatus, .failed)
        XCTAssertTrue(timedOut.message?.localizedCaseInsensitiveContains("timed out") == true)
        XCTAssertTrue(timedOut.rawOutput.contains("Flutter (3.24.1)"))
    }

    private func makeSDK(_ name: String, path: String, global: Bool = false) -> FlutterSDK {
        var sdk = FlutterSDK(name: name, type: "release", directory: path, flutterSdkVersion: name == "stable" ? "3.24.1" : name, isSetup: true)
        sdk.isGlobal = global
        return sdk
    }
}

private actor DoctorTestFVM: FVMService {
    struct Invocation: Sendable {
        let sdkDirectory: String
        let directory: URL?
        let timeout: Duration
    }
    enum Behavior: Sendable {
        case result(CLIResult)
        case delay(Duration, CLIResult)
        case timeout(String)
    }
    private let behavior: Behavior
    private(set) var lastInvocation: Invocation?

    init(behavior: Behavior) { self.behavior = behavior }
    func installed() async throws -> [FlutterSDK] { [] }
    func releases() async throws -> [FlutterRelease] { [] }
    func project(at url: URL) async throws -> (name: String, version: String?, isFlutter: Bool) { ("sample", nil, true) }
    func modify(_ arguments: [String], directory: URL?, output: OutputHandler?) async throws { }
    func runFlutter(_ command: ProjectFlutterCommand, directory: URL, output: OutputHandler?) async throws -> CLIResult { result("") }
    func runFlutterDoctor(sdk: FlutterSDK, directory: URL?, timeout: Duration, output: OutputHandler?) async throws -> CLIResult {
        lastInvocation = Invocation(sdkDirectory: sdk.directory, directory: directory, timeout: timeout)
        switch behavior {
        case .result(let result):
            await send(result, to: output)
            return result
        case .delay(let duration, let result):
            await send(result, to: output)
            try await Task.sleep(for: duration)
            try Task.checkCancellation()
            return result
        case .timeout(let outputText):
            await output?(CLIOutput(text: outputText, isError: false))
            throw CLIError.timedOut(URL(fileURLWithPath: sdk.directory).appendingPathComponent("bin/flutter"), timeout: timeout)
        }
    }

    private func send(_ result: CLIResult, to output: OutputHandler?) async {
        await output?(CLIOutput(text: result.stdout, isError: false))
        if !result.stderr.isEmpty { await output?(CLIOutput(text: result.stderr, isError: true)) }
    }
}
