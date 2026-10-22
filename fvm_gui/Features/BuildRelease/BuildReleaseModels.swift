import Foundation

enum ReleasePlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case androidAPK, androidAAB, iOSIPA, macOSApp
    var id: String { rawValue }
    var title: String {
        switch self { case .androidAPK: "Android APK"; case .androidAAB: "Android App Bundle"; case .iOSIPA: "iOS IPA"; case .macOSApp: "macOS App" }
    }
    var target: String {
        switch self { case .androidAPK: "apk"; case .androidAAB: "appbundle"; case .iOSIPA: "ipa"; case .macOSApp: "macos" }
    }
    var fileExtension: String { switch self { case .androidAPK: "apk"; case .androidAAB: "aab"; case .iOSIPA: "ipa"; case .macOSApp: "app" } }
    var isAndroid: Bool { self == .androidAPK || self == .androidAAB }
    var isIOS: Bool { self == .iOSIPA }
    var familyKey: String { isAndroid ? "android" : rawValue }
}

struct BuildDefine: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String
    var value: String
}

struct BuildConfiguration: Codable, Equatable, Sendable {
    var projectID: String
    var platform: ReleasePlatform = .androidAPK
    var buildMode: String = "release"
    var sdkVersion: String
    var flavor: String?
    var entrypoint = "lib/main.dart"
    var buildName = ""
    var buildNumber = ""
    var defines: [BuildDefine] = []
    var defineFile: String?
    var obfuscate = false
    var splitDebugInfo: String?
    var generateDebugSymbols = false
    var archiveRelease = true
    var treeShakeIcons = true
    var splitPerABI = false
    var exportOptionsPlist: String?
    var outputDestination: String?
    var additionalArguments: [String] = []

    func arguments() throws -> [String] {
        guard buildMode == "release" || buildMode == "profile" || buildMode == "debug" else { throw BuildValidationError("Choose a supported build mode.") }
        let trimmedEntrypoint = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEntrypoint.hasPrefix("lib/"), !trimmedEntrypoint.contains(".."), trimmedEntrypoint.hasSuffix(".dart") else {
            throw BuildValidationError("The Dart entrypoint must be a .dart file inside the project's lib directory.")
        }
        if let flavor, !flavor.isEmpty {
            guard !flavor.hasPrefix("-"), flavor.rangeOfCharacter(from: .newlines) == nil else {
                throw BuildValidationError("The selected flavor name is invalid.")
            }
        }
        guard additionalArguments.allSatisfy({ !$0.hasPrefix("-") || ["--no-codesign"].contains($0) }) else { throw BuildValidationError("Additional arguments cannot override generated options.") }
        if !platform.isAndroid && splitPerABI { throw BuildValidationError("Split per ABI is available only for Android builds.") }
        let debugInfoDirectory = splitDebugInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (obfuscate || generateDebugSymbols) && (debugInfoDirectory?.isEmpty ?? true) {
            throw BuildValidationError(obfuscate ? "Obfuscation requires a Split Debug Info directory." : "Generate Debug Symbols requires a Split Debug Info directory.")
        }
        var result = ["build", platform.target, "--\(buildMode)", "-t", trimmedEntrypoint]
        if let flavor, !flavor.isEmpty { result += ["--flavor", flavor] }
        if !buildName.isEmpty { result += ["--build-name", buildName] }
        if !buildNumber.isEmpty { result += ["--build-number", buildNumber] }
        for define in defines where !define.key.isEmpty { result += ["--dart-define", "\(define.key)=\(define.value)"] }
        if let defineFile, !defineFile.isEmpty { result += ["--dart-define-from-file", defineFile] }
        if obfuscate { result.append("--obfuscate") }
        if obfuscate || generateDebugSymbols {
            if let debugInfoDirectory, !debugInfoDirectory.isEmpty { result += ["--split-debug-info", debugInfoDirectory] }
        }
        if treeShakeIcons { result.append("--tree-shake-icons") }
        if platform == .androidAPK && splitPerABI { result.append("--split-per-abi") }
        if platform == .iOSIPA, let exportOptionsPlist, !exportOptionsPlist.isEmpty { result += ["--export-options-plist", exportOptionsPlist] }
        result += additionalArguments
        return result
    }
    var preview: String { (try? arguments().map(Self.displayArgument).joined(separator: " ")) ?? "Invalid configuration" }
    private static func displayArgument(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, platform, buildMode, sdkVersion, flavor, entrypoint, buildName, buildNumber, defines
        case defineFile, obfuscate, splitDebugInfo, generateDebugSymbols, archiveRelease, treeShakeIcons
        case splitPerABI, exportOptionsPlist, outputDestination, additionalArguments
    }

    init(
        projectID: String,
        platform: ReleasePlatform = .androidAPK,
        buildMode: String = "release",
        sdkVersion: String,
        flavor: String? = nil,
        entrypoint: String = "lib/main.dart",
        buildName: String = "",
        buildNumber: String = "",
        defines: [BuildDefine] = [],
        defineFile: String? = nil,
        obfuscate: Bool = false,
        splitDebugInfo: String? = nil,
        generateDebugSymbols: Bool = false,
        archiveRelease: Bool = true,
        treeShakeIcons: Bool = true,
        splitPerABI: Bool = false,
        exportOptionsPlist: String? = nil,
        outputDestination: String? = nil,
        additionalArguments: [String] = []
    ) {
        self.projectID = projectID
        self.platform = platform
        self.buildMode = buildMode
        self.sdkVersion = sdkVersion
        self.flavor = flavor
        self.entrypoint = entrypoint
        self.buildName = buildName
        self.buildNumber = buildNumber
        self.defines = defines
        self.defineFile = defineFile
        self.obfuscate = obfuscate
        self.splitDebugInfo = splitDebugInfo
        self.generateDebugSymbols = generateDebugSymbols
        self.archiveRelease = archiveRelease
        self.treeShakeIcons = treeShakeIcons
        self.splitPerABI = splitPerABI
        self.exportOptionsPlist = exportOptionsPlist
        self.outputDestination = outputDestination
        self.additionalArguments = additionalArguments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try values.decode(String.self, forKey: .projectID)
        platform = try values.decodeIfPresent(ReleasePlatform.self, forKey: .platform) ?? .androidAPK
        buildMode = try values.decodeIfPresent(String.self, forKey: .buildMode) ?? "release"
        sdkVersion = try values.decodeIfPresent(String.self, forKey: .sdkVersion) ?? "Unknown"
        flavor = try values.decodeIfPresent(String.self, forKey: .flavor)
        entrypoint = try values.decodeIfPresent(String.self, forKey: .entrypoint) ?? "lib/main.dart"
        buildName = try values.decodeIfPresent(String.self, forKey: .buildName) ?? ""
        buildNumber = try values.decodeIfPresent(String.self, forKey: .buildNumber) ?? ""
        defines = try values.decodeIfPresent([BuildDefine].self, forKey: .defines) ?? []
        defineFile = try values.decodeIfPresent(String.self, forKey: .defineFile)
        obfuscate = try values.decodeIfPresent(Bool.self, forKey: .obfuscate) ?? false
        splitDebugInfo = try values.decodeIfPresent(String.self, forKey: .splitDebugInfo)
        generateDebugSymbols = try values.decodeIfPresent(Bool.self, forKey: .generateDebugSymbols) ?? false
        archiveRelease = try values.decodeIfPresent(Bool.self, forKey: .archiveRelease) ?? true
        treeShakeIcons = try values.decodeIfPresent(Bool.self, forKey: .treeShakeIcons) ?? true
        splitPerABI = try values.decodeIfPresent(Bool.self, forKey: .splitPerABI) ?? false
        exportOptionsPlist = try values.decodeIfPresent(String.self, forKey: .exportOptionsPlist)
        outputDestination = try values.decodeIfPresent(String.self, forKey: .outputDestination)
        additionalArguments = try values.decodeIfPresent([String].self, forKey: .additionalArguments) ?? []
    }
}

struct BuildValidationError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum BuildJobStatus: String, Codable, Sendable { case running, succeeded, failed, cancelled }
enum BuildStage: String, CaseIterable, Codable, Sendable { case preparing, validating, resolvingDependencies, compiling, packaging, archiving, finalizing, completed, failed, cancelled
    var title: String { switch self { case .preparing: "Preparing Release"; case .validating: "Validating"; case .resolvingDependencies: "Resolving Dependencies"; case .compiling: "Compiling"; case .packaging: "Packaging"; case .archiving: "Archiving Release"; case .finalizing: "Finalizing"; case .completed: "Completed"; case .failed: "Failed"; case .cancelled: "Cancelled" } }
}

enum ReleaseArchiveStatus: String, Codable, Sendable { case pending, archived, partial, failed, missing, notRequested }

struct BuildHistoryRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var configuration: BuildConfiguration
    var sdkLabel: String
    var startedAt: Date
    var endedAt: Date?
    var status: BuildJobStatus
    /// Flutter compilation result is tracked separately from archive completion.
    var buildStatus: BuildJobStatus? = nil
    var stage: BuildStage
    var exitCode: Int32?
    var artifactPath: String?
    var exportedArtifactPath: String?
    var exportError: String?
    var log: String
    var logFilePath: String? = nil
    var error: String?
    var archiveStatus: ReleaseArchiveStatus? = nil
    var projectIdentity: String? = nil
    var releaseDirectory: String? = nil
    var archivedArtifacts: [String]? = nil
    var archivedSymbolFiles: [String]? = nil
    var archivedSizeBytes: Int64? = nil
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

enum FlavorConfidence: String, Codable, Hashable, Sendable {
    case confirmedFlavor
    case potentialFlavor
    case ordinaryScheme
    case invalidConfiguration

    var title: String {
        switch self {
        case .confirmedFlavor: "Confirmed Flutter flavor"
        case .potentialFlavor: "Potential flavor"
        case .ordinaryScheme: "Ordinary Xcode scheme"
        case .invalidConfiguration: "Invalid or incomplete configuration"
        }
    }

    var isSelectableFlavor: Bool {
        switch self {
        case .confirmedFlavor, .potentialFlavor: true
        case .ordinaryScheme, .invalidConfiguration: false
        }
    }
}

struct DetectedFlavor: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var source: String
    var verified: Bool
    var confidence: FlavorConfidence
    var schemeName: String?
    var buildConfigurations: [String]
    var explanation: String?

    init(
        name: String,
        source: String,
        verified: Bool,
        confidence: FlavorConfidence? = nil,
        schemeName: String? = nil,
        buildConfigurations: [String] = [],
        explanation: String? = nil
    ) {
        self.name = name
        self.source = source
        self.verified = verified
        self.confidence = confidence ?? (verified ? .confirmedFlavor : .potentialFlavor)
        self.schemeName = schemeName
        self.buildConfigurations = buildConfigurations
        self.explanation = explanation
    }
}

struct DiscoveredXcodeScheme: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var confidence: FlavorConfidence
    var buildConfigurations: [String] = []
    var launchConfiguration: String?
    var archiveConfiguration: String?
    var profileConfiguration: String?
    var testConfiguration: String?
    var analyzeConfiguration: String?
    var targetNames: [String] = []
    var isSharedOnDisk: Bool = false
    var isListedByXcodebuild: Bool = false
    var explanation: String?
}

struct FlavorDiscoveryDiagnostics: Codable, Equatable, Sendable {
    var platform: ReleasePlatform
    var containerPath: String?
    var projectPath: String?
    var discoveredSchemes: [DiscoveredXcodeScheme] = []
    var discoveredBuildConfigurations: [String] = []
    var discoveredTargets: [String] = []
    var flavors: [DetectedFlavor] = []
    var localSchemes: [String] = []
    var warnings: [String] = []
    var errors: [String] = []
    var emptyStateExplanation: String?
    var discoveryDurationSeconds: TimeInterval?

    var validatedFlavors: [DetectedFlavor] {
        flavors.filter { $0.confidence == .confirmedFlavor }
    }

    var potentialFlavors: [DetectedFlavor] {
        flavors.filter { $0.confidence == .potentialFlavor }
    }
}

enum EntrypointConfidence: String, Codable, Hashable, Sendable {
    case confirmed
    case potential

    var title: String {
        switch self {
        case .confirmed: "Confirmed entrypoint"
        case .potential: "Potential entrypoint"
        }
    }
}

struct DetectedEntrypoint: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var confidence: EntrypointConfidence
    var signature: String?
    var explanation: String?

    var verified: Bool { confidence == .confirmed }
}

struct DartEntrypointDiscoveryResult: Codable, Equatable, Sendable {
    var entrypoints: [DetectedEntrypoint] = []
    var warnings: [String] = []
    var errors: [String] = []
}

struct BuildPreset: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var configuration: BuildConfiguration
    var isDefault = false
}
