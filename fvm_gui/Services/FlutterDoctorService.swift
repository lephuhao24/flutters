import Foundation

actor FlutterDoctorService {
    static let timeout: Duration = .seconds(120)

    private var fvm: (any FVMService)?
    private let parser: FlutterDoctorParser
    private let clock = ContinuousClock()

    init(fvm: (any FVMService)? = nil, parser: FlutterDoctorParser = FlutterDoctorParser()) {
        self.fvm = fvm
        self.parser = parser
    }

    func configure(fvm: (any FVMService)?) { self.fvm = fvm }

    func inspect(sdk: FlutterSDK?, project: FlutterProject?, operationID: UUID,
                 activity: ActivityStore) async -> FlutterDoctorReport {
        let command = "flutter doctor --verbose · \(sdk?.name ?? "SDK unavailable")"
        let projectPath = project.map { Self.canonicalPath($0.path) }
        let logID = await activity.begin(command: command, projectPath: projectPath, id: operationID)
        let started = clock.now
        guard let sdk else {
            let reason = project == nil ? "No installed Flutter SDK is available to inspect." : "This project has no installed effective Flutter SDK."
            let category = FlutterDoctorCategory(identifier: "flutter-sdk", name: "Flutter SDK", status: .failed,
                                                 diagnosticMessages: [reason],
                                                 suggestedActions: [FlutterDoctorSuggestedAction(id: "install-flutter", title: "Install a Flutter SDK", instructions: "Install an SDK with FVM, then refresh the SDK list and run Doctor again.", documentationURL: "https://fvm.app/documentation/getting-started")],
                                                 rawOutput: reason)
            await activity.append(reason, id: logID)
            await activity.finish(logID, status: .failed, duration: started.duration(to: clock.now))
            return FlutterDoctorReport(id: operationID, sdkName: nil, flutterVersion: nil, sdkPath: nil,
                                       projectName: project?.name, projectPath: projectPath,
                                       executionStatus: .failed, exitCode: nil, duration: started.duration(to: clock.now),
                                       overallStatus: .failed, categories: [category], rawOutput: reason, message: reason)
        }
        guard sdk.isSetup else {
            let reason = "Flutter SDK \(sdk.name) is installed but setup is incomplete."
            await activity.append(reason, id: logID)
            await activity.finish(logID, status: .failed, duration: started.duration(to: clock.now))
            let category = FlutterDoctorCategory(identifier: "flutter-sdk", name: "Flutter SDK", status: .failed,
                                                 diagnosticMessages: [reason], suggestedActions: [], rawOutput: reason)
            return report(id: operationID, sdk: sdk, project: project, status: .failed, exitCode: nil,
                          duration: started.duration(to: clock.now), overall: .failed,
                          categories: [category], output: reason, message: reason)
        }
        guard let fvm else {
            let reason = "FVM is unavailable. Configure FVM before running Flutter Doctor."
            await activity.append(reason, id: logID)
            await activity.finish(logID, status: .failed, duration: started.duration(to: clock.now))
            return report(id: operationID, sdk: sdk, project: project, status: .failed, exitCode: nil,
                          duration: started.duration(to: clock.now), overall: .failed, categories: [], output: reason, message: reason)
        }

        let outputBuffer = DoctorOutputBuffer()
        do {
            let result = try await fvm.runFlutterDoctor(sdk: sdk,
                                                        directory: project.map { URL(fileURLWithPath: $0.path, isDirectory: true) },
                                                        timeout: Self.timeout,
                                                        output: { event in
                await outputBuffer.append(event.text, isError: event.isError)
                await activity.append((event.isError ? "[stderr] " : "") + event.text, id: logID)
            })
            let output = Self.joinOutput(stdout: result.stdout, stderr: result.stderr)
            let parsed = Self.parse(output, with: parser)
            let operationStatus: OperationStatus = result.exitCode == 0 ? .completed : .failed
            let overall = result.exitCode == 0 ? parsed.overallStatus : .failed
            let message = result.exitCode == 0 ? parsed.message : "Flutter Doctor exited with code \(result.exitCode). Review the raw output and Activity log."
            await activity.finish(logID, status: operationStatus, exitCode: result.exitCode, duration: started.duration(to: clock.now))
            return report(id: operationID, sdk: sdk, project: project, status: operationStatus,
                          exitCode: result.exitCode, duration: started.duration(to: clock.now), overall: overall,
                          categories: parsed.categories, output: output, message: message)
        } catch is CancellationError {
            let captured = await outputBuffer.snapshot()
            let partialOutput: String
            if captured.isEmpty { partialOutput = await activity.output(for: logID) }
            else { partialOutput = captured }
            let parsed = Self.parse(partialOutput, with: parser)
            await activity.finish(logID, status: .cancelled, duration: started.duration(to: clock.now))
            return report(id: operationID, sdk: sdk, project: project, status: .cancelled, exitCode: nil,
                          duration: started.duration(to: clock.now), overall: .unknown, categories: parsed.categories,
                          output: partialOutput, message: "Flutter Doctor was cancelled. Results may be incomplete.")
        } catch {
            let captured = await outputBuffer.snapshot()
            let partialOutput: String
            if captured.isEmpty { partialOutput = await activity.output(for: logID) }
            else { partialOutput = captured }
            let parsed = Self.parse(partialOutput, with: parser)
            await activity.append("\n\(error.localizedDescription)", id: logID)
            await activity.finish(logID, status: .failed, duration: started.duration(to: clock.now))
            return report(id: operationID, sdk: sdk, project: project, status: .failed, exitCode: nil,
                          duration: started.duration(to: clock.now), overall: .failed, categories: parsed.categories,
                          output: partialOutput, message: error.localizedDescription)
        }
    }

    private func report(id: UUID, sdk: FlutterSDK?, project: FlutterProject?, status: OperationStatus,
                        exitCode: Int32?, duration: Duration, overall: FlutterDiagnosticStatus,
                        categories: [FlutterDoctorCategory], output: String, message: String?) -> FlutterDoctorReport {
        FlutterDoctorReport(id: id, sdkName: sdk?.name, flutterVersion: sdk?.flutterSdkVersion,
                            sdkPath: sdk?.directory, projectName: project?.name,
                            projectPath: project.map { Self.canonicalPath($0.path) },
                            executionStatus: status, exitCode: exitCode, duration: duration,
                            overallStatus: overall, categories: categories, rawOutput: output, message: message)
    }

    private static func parse(_ output: String, with parser: FlutterDoctorParser) -> FlutterDoctorParseResult {
        do { return try parser.parse(output) }
        catch {
            return FlutterDoctorParseResult(categories: [], formatRecognized: false,
                                            hasCompletionSummary: false,
                                            message: "Structured parsing failed: \(error.localizedDescription)")
        }
    }

    private static func joinOutput(stdout: String, stderr: String) -> String {
        guard !stdout.isEmpty else { return stderr }
        guard !stderr.isEmpty else { return stdout }
        return stdout + "\n[stderr]\n" + stderr
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private actor DoctorOutputBuffer {
    private var value = ""
    func append(_ text: String, isError: Bool) {
        if isError { value += "[stderr] " }
        value += text
    }
    func snapshot() -> String { value }
}
