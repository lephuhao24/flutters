import Foundation

protocol FlutterSDKMetadataProviding: Sendable {
    func metadata(for sdk: FlutterSDK, forceRefresh: Bool) async -> FlutterSDKMetadata
}

protocol PubConstraintEvaluating: Sendable {
    func evaluate(sdk: FlutterSDK, metadata: FlutterSDKMetadata, dartConstraint: String,
                  flutterConstraint: String?) async -> PubConstraintEvaluation
}

protocol ProjectCompatibilityServicing: Sendable {
    func evaluate(project: FlutterProject, sdk: FlutterSDK?, installedSDKs: [FlutterSDK], forceRefresh: Bool) async -> ProjectCompatibility
}

enum PubConstraintEvaluation: Sendable, Equatable {
    case compatible
    case incompatible(String)
    case unableToEvaluate(String)
}

actor FlutterSDKMetadataService: FlutterSDKMetadataProviding {
    private let executor: any CLIExecuting
    private let fileSystem: any FileSystemOperating
    private var cache: [String: FlutterSDKMetadata] = [:]

    init(executor: any CLIExecuting = CLIExecutor(), fileSystem: any FileSystemOperating = LocalFileSystem()) {
        self.executor = executor
        self.fileSystem = fileSystem
    }

    func metadata(for sdk: FlutterSDK, forceRefresh: Bool = false) async -> FlutterSDKMetadata {
        let directory = URL(fileURLWithPath: sdk.directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let flutterFile = directory.appendingPathComponent("version")
        let dartFile = directory.appendingPathComponent("bin/cache/dart-sdk/version")
        let flutterFileContents = try? await fileSystem.read(flutterFile)
        let dartFileContents = try? await fileSystem.read(dartFile)
        let flutterFromFile = Self.versionString(flutterFileContents)
        let dartFromFile = Self.versionString(dartFileContents)
        let signature = [sdk.name, directory.path, sdk.flutterSdkVersion ?? "", String(sdk.isSetup),
                         flutterFileContents?.base64EncodedString() ?? "missing", dartFileContents?.base64EncodedString() ?? "missing"]
            .joined(separator: "\u{1f}")
        if !forceRefresh, let cached = cache[signature] { return cached }

        guard sdk.isSetup else {
            let result = FlutterSDKMetadata(sdkName: sdk.name, directory: directory.path,
                                            flutterVersion: sdk.flutterSdkVersion ?? flutterFromFile,
                                            dartSDKVersion: dartFromFile, isInstalled: true, isSetup: false,
                                            fingerprint: signature, issue: "SDK setup is incomplete.")
            cache[signature] = result
            return result
        }

        var flutterVersion = sdk.flutterSdkVersion ?? flutterFromFile
        var dartVersion = dartFromFile
        var issue: String?
        if flutterVersion == nil || dartVersion == nil {
            do {
                let result = try await executor.run(executable: directory.appendingPathComponent("bin/flutter"),
                                                    arguments: ["--version", "--machine"], directory: nil,
                                                    timeout: .seconds(25), output: nil)
                guard result.exitCode == 0,
                      let payload = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
                    throw FVMError.message(result.stderr.isEmpty ? "Flutter did not return SDK metadata." : result.stderr)
                }
                flutterVersion = flutterVersion ?? payload["flutterVersion"] as? String
                dartVersion = dartVersion ?? payload["dartSdkVersion"] as? String
            } catch { issue = error.localizedDescription }
        }
        if dartVersion == nil { issue = issue ?? "The bundled Dart SDK version metadata is unavailable." }
        if flutterVersion == nil { issue = issue ?? "The Flutter SDK version metadata is unavailable." }
        let result = FlutterSDKMetadata(sdkName: sdk.name, directory: directory.path,
                                        flutterVersion: flutterVersion, dartSDKVersion: dartVersion,
                                        isInstalled: true, isSetup: true, fingerprint: signature, issue: issue)
        cache[signature] = result
        return result
    }

    private static func versionString(_ data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Uses the selected SDK's own Pub solver against a temporary, dependency-free
/// manifest. Pub is the authority for pub_semver and Flutter SDK constraint rules.
actor PubConstraintEvaluator: PubConstraintEvaluating {
    private let executor: any CLIExecuting
    private let fileSystem: any FileSystemOperating
    private var cache: [String: PubConstraintEvaluation] = [:]

    init(executor: any CLIExecuting = CLIExecutor(), fileSystem: any FileSystemOperating = LocalFileSystem()) {
        self.executor = executor
        self.fileSystem = fileSystem
    }

    func evaluate(sdk: FlutterSDK, metadata: FlutterSDKMetadata, dartConstraint: String,
                  flutterConstraint: String? = nil) async -> PubConstraintEvaluation {
        let key = [metadata.fingerprint, metadata.flutterVersion ?? "", metadata.dartSDKVersion ?? "",
                   dartConstraint, flutterConstraint ?? ""].joined(separator: "\u{1f}")
        if let cached = cache[key] { return cached }
        guard metadata.isSetup else { return .unableToEvaluate("The Flutter SDK setup is incomplete.") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FVM-GUI-Pub-Check-\(UUID().uuidString)", isDirectory: true)
        do {
            try await fileSystem.createDirectory(directory)
            var environment: [String: String] = ["sdk": dartConstraint]
            if let flutterConstraint, !flutterConstraint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                environment["flutter"] = flutterConstraint
            }
            let manifest: [String: Any] = ["name": "fvm_gui_compatibility_probe", "publish_to": "none", "environment": environment]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try await fileSystem.write(data, to: directory.appendingPathComponent("pubspec.yaml"))
            try Task.checkCancellation()
            let result = try await executor.run(executable: URL(fileURLWithPath: sdk.directory).appendingPathComponent("bin/flutter"),
                                                arguments: ["pub", "get", "--offline"], directory: directory,
                                                timeout: .seconds(35), output: nil)
            let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let evaluation: PubConstraintEvaluation
            if result.exitCode == 0 {
                evaluation = .compatible
            } else {
                evaluation = Self.classifyFailure(output)
            }
            try? await fileSystem.remove(directory)
            cache[key] = evaluation
            return evaluation
        } catch is CancellationError {
            try? await fileSystem.remove(directory)
            return .unableToEvaluate("Compatibility evaluation was cancelled.")
        } catch {
            try? await fileSystem.remove(directory)
            return .unableToEvaluate(error.localizedDescription)
        }
    }

    private static func classifyFailure(_ output: String) -> PubConstraintEvaluation {
        let normalized = output.lowercased()
        if ["invalid version constraint", "could not parse version constraint", "invalid sdk constraint", "no lower-bound sdk constraint"]
            .contains(where: normalized.contains) {
            return .unableToEvaluate(output.isEmpty ? "Pub rejected the SDK constraint syntax." : output)
        }
        if normalized.contains("version solving failed") || normalized.contains("does not match the current") || normalized.contains("requires sdk version") {
            return .incompatible(output.isEmpty ? "The selected SDK does not satisfy the declared constraints." : output)
        }
        return .unableToEvaluate(output.isEmpty ? "Pub could not evaluate the SDK constraints." : output)
    }
}

actor ProjectCompatibilityService: ProjectCompatibilityServicing {
    private let manifestReader: any ProjectManifestReading
    private let metadataService: any FlutterSDKMetadataProviding
    private let constraintEvaluator: any PubConstraintEvaluating
    private var cache: [String: ProjectCompatibility] = [:]

    init(manifestReader: any ProjectManifestReading = ProjectManifestReader(),
         metadataService: any FlutterSDKMetadataProviding = FlutterSDKMetadataService(),
         constraintEvaluator: any PubConstraintEvaluating = PubConstraintEvaluator()) {
        self.manifestReader = manifestReader
        self.metadataService = metadataService
        self.constraintEvaluator = constraintEvaluator
    }

    func evaluate(project: FlutterProject, sdk: FlutterSDK?, installedSDKs: [FlutterSDK], forceRefresh: Bool = false) async -> ProjectCompatibility {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let fresh: FlutterProject
        do { fresh = try await manifestReader.read(URL(fileURLWithPath: project.path, isDirectory: true), within: root) }
        catch { return result(project: project, sdk: sdk, metadata: nil, status: .unableToEvaluate,
                              explanation: error.localizedDescription, recommendation: "Fix or restore the project's pubspec.yaml and FVM configuration, then refresh.") }

        let effectiveVersion = project.version ?? fresh.configuredVersion
        guard fresh.type != .dartPackage else {
            return result(project: fresh, sdk: sdk, metadata: nil, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .unknown,
                          explanation: "Dart-only packages do not select a Flutter SDK in FVM.",
                          recommendation: "Use a Dart SDK compatibility check for this package.")
        }
        if let sdk, !installedSDKs.contains(where: { $0.name == sdk.name && $0.directory == sdk.directory }) {
            return result(project: fresh, sdk: nil, metadata: nil, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .sdkMissing,
                          explanation: "The selected Flutter SDK is no longer installed.",
                          recommendation: "Refresh installed SDKs and choose an available version.")
        }
        guard let sdk else {
            return result(project: fresh, sdk: nil, metadata: nil, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .sdkMissing,
                          explanation: effectiveVersion.map { "Configured Flutter SDK \($0) is not installed." } ?? "No effective Flutter SDK is configured for this project.",
                          recommendation: "Install the configured SDK or select an installed Flutter version.")
        }
        let metadata = await metadataService.metadata(for: sdk, forceRefresh: forceRefresh)
        guard metadata.isSetup else {
            return result(project: fresh, sdk: sdk, metadata: metadata, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .unknown,
                          explanation: metadata.issue ?? "The selected SDK is not ready.",
                          recommendation: "Complete SDK setup and refresh compatibility.")
        }
        guard let dartConstraint = fresh.dartSDKConstraint, !dartConstraint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(project: fresh, sdk: sdk, metadata: metadata, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .unknown,
                          explanation: "pubspec.yaml does not declare environment.sdk, so compatibility cannot be confirmed.",
                          recommendation: "Declare an environment.sdk constraint before relying on this result.")
        }
        guard metadata.dartSDKVersion != nil else {
            return result(project: fresh, sdk: sdk, metadata: metadata, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .unknown,
                          explanation: metadata.issue ?? "The bundled Dart SDK version is unavailable.",
                          recommendation: "Repair or reinstall this SDK, then refresh.")
        }
        if fresh.flutterSDKConstraint != nil && metadata.flutterVersion == nil {
            return result(project: fresh, sdk: sdk, metadata: metadata, configured: fresh.configuredVersion,
                          effective: effectiveVersion, status: .unknown,
                          explanation: metadata.issue ?? "The Flutter SDK version is unavailable.",
                          recommendation: "Refresh the SDK metadata before evaluating the Flutter constraint.")
        }

        let cacheKey = [fresh.path, fresh.name, fresh.type.rawValue, fresh.configurationSource ?? "", fresh.configuredVersion ?? "", effectiveVersion ?? "",
                        metadata.fingerprint, metadata.flutterVersion ?? "", metadata.dartSDKVersion ?? "",
                        fresh.dartSDKConstraint ?? "", fresh.flutterSDKConstraint ?? ""].joined(separator: "\u{1f}")
        if !forceRefresh, let cached = cache[cacheKey] { return cached }
        let evaluation = await constraintEvaluator.evaluate(sdk: sdk, metadata: metadata,
                                                            dartConstraint: dartConstraint,
                                                            flutterConstraint: fresh.flutterSDKConstraint)
        let status: ProjectCompatibilityStatus
        let explanation: String
        let recommendation: String
        switch evaluation {
        case .compatible:
            status = .compatible
            explanation = "Pub confirms Dart \(metadata.dartSDKVersion ?? "unknown") and Flutter \(metadata.flutterVersion ?? "unknown") satisfy this project's SDK constraints."
            recommendation = "No change is needed."
        case .incompatible(let reason):
            status = .incompatible
            explanation = Self.concise(reason)
            recommendation = "Choose a compatible installed SDK, or update the constraints intentionally."
        case .unableToEvaluate(let reason):
            status = .unableToEvaluate
            explanation = Self.concise(reason)
            recommendation = "Review the manifest and SDK output, then run flutter pub get to inspect the full diagnostic."
        }
        let result = ProjectCompatibility(projectName: fresh.name, projectPath: fresh.path,
                                          configurationSource: fresh.configurationSource,
                                          configuredFlutterVersion: fresh.configuredVersion,
                                          effectiveFlutterVersion: effectiveVersion,
                                          selectedFlutterSDK: sdk.name,
                                          selectedFlutterVersion: metadata.flutterVersion,
                                          bundledDartSDKVersion: metadata.dartSDKVersion,
                                          requiredDartConstraint: fresh.dartSDKConstraint,
                                          requiredFlutterConstraint: fresh.flutterSDKConstraint,
                                          status: status, explanation: explanation, recommendedAction: recommendation)
        cache[cacheKey] = result
        return result
    }

    private func result(project: FlutterProject, sdk: FlutterSDK?, metadata: FlutterSDKMetadata?, configured: String? = nil,
                        effective: String? = nil, status: ProjectCompatibilityStatus, explanation: String,
                        recommendation: String) -> ProjectCompatibility {
        ProjectCompatibility(projectName: project.name, projectPath: project.path,
                             configurationSource: project.configurationSource,
                             configuredFlutterVersion: configured ?? project.configuredVersion,
                             effectiveFlutterVersion: effective ?? project.version ?? project.configuredVersion,
                             selectedFlutterSDK: sdk?.name, selectedFlutterVersion: metadata?.flutterVersion,
                             bundledDartSDKVersion: metadata?.dartSDKVersion,
                             requiredDartConstraint: project.dartSDKConstraint,
                             requiredFlutterConstraint: project.flutterSDKConstraint,
                             status: status, explanation: explanation, recommendedAction: recommendation)
    }

    private static func concise(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return lines.suffix(5).joined(separator: "\n")
    }
}
