import Foundation
import Observation
import OSLog

// MARK: - Flutter CLI option capabilities

enum FlutterOptionSupport: String, Codable, Sendable {
    case supported
    case unsupported
    case unknown
}

struct FlutterCLIOptionParser: Sendable {
    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:-\w,\s*)?(--(?:\[no-\])?[A-Za-z][A-Za-z0-9-]*(?:=<[^>\r\n]+>|=[^\s,]+)?)"#
    )

    func parse(_ output: String) -> Set<String> {
        var flags = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = Self.declaration.firstMatch(in: line, range: range),
                  let tokenRange = Range(match.range(at: 1), in: line) else { continue }
            let token = String(line[tokenRange])
            if let nameRange = token.range(of: #"--\[no-\]"#, options: .regularExpression) {
                let name = String(token[nameRange.upperBound...])
                flags.insert("--\(name)")
                flags.insert("--no-\(name)")
            } else {
                let name = token.dropFirst(2).split(whereSeparator: { $0 == "=" }).first.map(String.init) ?? ""
                if !name.isEmpty { flags.insert("--\(name)") }
            }
        }
        return flags
    }
}

struct FlutterSDKIdentity: Codable, Hashable, Sendable {
    let executablePath: String
    let sdkVersion: String
    let executableSize: Int64
    let executableModifiedAt: TimeInterval

    init(executable: URL, sdkVersion: String) {
        let canonical = executable.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path)
        self.executablePath = canonical.path
        self.sdkVersion = sdkVersion
        self.executableSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        self.executableModifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    var cacheKey: String { "\(executablePath)|\(sdkVersion)|\(executableSize)|\(executableModifiedAt)" }
}

struct CachedFlutterOptionProbe: Codable, Sendable {
    let schemaVersion: Int
    let identity: FlutterSDKIdentity
    let target: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

final class FlutterOptionCapabilityCache: @unchecked Sendable {
    static let shared = FlutterOptionCapabilityCache()
    static let schemaVersion = 2
    private static let storageKey = "buildRelease.flutterOptionCapabilities.schema2"
    private static let obsoleteKeys = [
        "buildRelease.flutterOptionCapabilities.schema1",
        "buildRelease.flutterOptionCapabilities.v1",
        "buildRelease.flutterCapabilities.v1"
    ]
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.obsoleteKeys.forEach(defaults.removeObject(forKey:))
    }

    func probe(for identity: FlutterSDKIdentity, target: String) -> CachedFlutterOptionProbe? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.storageKey),
              let entries = try? JSONDecoder().decode([String: CachedFlutterOptionProbe].self, from: data),
              let entry = entries[Self.entryKey(identity: identity, target: target)],
              entry.schemaVersion == Self.schemaVersion,
              entry.identity == identity, entry.target == target else { return nil }
        return entry
    }

    func store(_ probe: CachedFlutterOptionProbe) {
        guard probe.schemaVersion == Self.schemaVersion, probe.exitCode == 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var entries = (try? defaults.data(forKey: Self.storageKey).map { try JSONDecoder().decode([String: CachedFlutterOptionProbe].self, from: $0) }) ?? [:]
        entries[Self.entryKey(identity: probe.identity, target: probe.target)] = probe
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.storageKey) }
    }

    private static func entryKey(identity: FlutterSDKIdentity, target: String) -> String {
        "\(schemaVersion)|\(identity.cacheKey)|\(target)"
    }
}

struct FlutterCapabilityProbe: Sendable {
    let executable: URL
    let sdkVersion: String
    let target: String
    let helpArguments: [String]
    let exitCode: Int32?
    let stdout: String
    let stderr: String
    let parsedFlags: Set<String>
    let requestedFlags: [String]
    let states: [String: FlutterOptionSupport]
    let cacheHit: Bool

    var isComplete: Bool {
        guard exitCode == 0, !parsedFlags.isEmpty else { return false }
        return (stdout + "\n" + stderr).localizedCaseInsensitiveContains("usage: flutter build \(target)")
    }
}

private let flutterCapabilityLogger = Logger(subsystem: "dev.fvmgui", category: "FlutterBuildCapabilities")

// MARK: - Flutter Build Service

actor FlutterBuildService {
    private let sdkDirectory: String?
    private let executor: any CLIExecuting
    private let capabilityCache: FlutterOptionCapabilityCache
    private let optionParser = FlutterCLIOptionParser()
    private var activeTargets = Set<String>()

    init(fvm: FVMInstallation, sdkDirectory: String?, executor: any CLIExecuting, capabilityCache: FlutterOptionCapabilityCache = .shared) {
        _ = fvm
        self.sdkDirectory = sdkDirectory
        self.executor = executor
        self.capabilityCache = capabilityCache
    }

    var selectedFlutterExecutable: URL? {
        sdkDirectory.map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("bin/flutter") }
    }

    func validate(_ config: BuildConfiguration, project: URL) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: project.appendingPathComponent("pubspec.yaml").path) else {
            throw BuildValidationError("The selected folder is not an accessible Flutter project (pubspec.yaml is missing).")
        }
        guard let flutter = selectedFlutterExecutable, FileManager.default.isExecutableFile(atPath: flutter.path) else {
            throw BuildValidationError("Flutter SDK \(config.sdkVersion) is missing or not set up.")
        }
        let canonicalProject = project.standardizedFileURL.resolvingSymlinksInPath().path
        let entry = project.appendingPathComponent(config.entrypoint).standardizedFileURL.resolvingSymlinksInPath()
        guard entry.path.hasPrefix(canonicalProject + "/"), FileManager.default.fileExists(atPath: entry.path) else {
            throw BuildValidationError("Dart entrypoint \(config.entrypoint) does not exist inside the project.")
        }
        if config.platform.isAndroid {
            guard FileManager.default.fileExists(atPath: project.appendingPathComponent("android/app").path) else {
                throw BuildValidationError("Android project files are missing.")
            }
            if ProcessInfo.processInfo.environment["ANDROID_HOME"] == nil && ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] == nil {
                // FVM's configured process PATH is authoritative for execution; this is a warning in the UI.
            }
        } else {
            if config.platform == .iOSIPA {
                let container = IOSFlavorDetector.locateXcodeContainer(in: project)
                if container.workspaceURL == nil && container.projectURL == nil {
                    throw BuildValidationError("The iOS Xcode project or workspace is missing.")
                }
            }
            if config.platform == .macOSApp {
                let macosDir = project.appendingPathComponent("macos")
                let items = (try? FileManager.default.contentsOfDirectory(at: macosDir, includingPropertiesForKeys: nil)) ?? []
                let hasXcode = items.contains { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }
                if !hasXcode {
                    throw BuildValidationError("The macOS Xcode project is missing.")
                }
            }
        }
        _ = try config.arguments()
        let requested = Self.requestedOptions(for: config)
        let probe = try await probeOptions(executable: flutter, sdkVersion: config.sdkVersion, target: config.platform.target, project: project, requested: requested)
        Self.log(probe)
        let unsupported = requested.filter { probe.states[$0] == .unsupported }
        if !unsupported.isEmpty {
            throw BuildValidationError("Flutter \(config.sdkVersion) does not support these requested options for \(config.platform.title): \(unsupported.joined(separator: ", ")).")
        }
    }

    func run(_ config: BuildConfiguration, project: URL, output: OutputHandler?) async throws -> CLIResult {
        let buildDirectory: String = config.platform.isAndroid ? "android" : (config.platform == .iOSIPA ? "ios" : "macos")
        let lock = project.standardizedFileURL.path + ":" + buildDirectory
        guard activeTargets.insert(lock).inserted else {
            throw BuildValidationError("A build for this project and target is already running.")
        }
        defer { activeTargets.remove(lock) }
        guard let flutter = selectedFlutterExecutable else { throw BuildValidationError("The selected Flutter SDK is unavailable.") }
        return try await executor.run(
            executable: flutter,
            arguments: try config.arguments(),
            directory: project,
            timeout: nil,
            output: output
        )
    }

    func probeOptions(executable: URL, sdkVersion: String, target: String, project: URL, requested: [String]) async throws -> FlutterCapabilityProbe {
        let helpArguments = ["build", target, "-h", "-v"]
        let identity = FlutterSDKIdentity(executable: executable, sdkVersion: sdkVersion)
        let cached = capabilityCache.probe(for: identity, target: target)
        let result: CachedFlutterOptionProbe?
        if let cached { result = cached }
        else {
            do {
                let response = try await executor.run(executable: executable, arguments: helpArguments, directory: project, timeout: .seconds(45), output: nil)
                let captured = CachedFlutterOptionProbe(schemaVersion: FlutterOptionCapabilityCache.schemaVersion, identity: identity, target: target, exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
                let parsedFlags = optionParser.parse(response.stdout + "\n" + response.stderr)
                let complete = response.exitCode == 0 && !parsedFlags.isEmpty
                    && (response.stdout + "\n" + response.stderr).localizedCaseInsensitiveContains("usage: flutter build \(target)")
                if complete { capabilityCache.store(captured) }
                result = captured
            } catch is CancellationError { throw CancellationError() }
            catch { result = nil }
        }

        let stdout = result?.stdout ?? ""
        let stderr = result?.stderr ?? ""
        let parsed = optionParser.parse(stdout + "\n" + stderr)
        let complete = result.map {
            $0.exitCode == 0 && !parsed.isEmpty && (stdout + "\n" + stderr).localizedCaseInsensitiveContains("usage: flutter build \(target)")
        } ?? false
        let states = Dictionary(uniqueKeysWithValues: requested.map { flag in
            (flag, complete ? (parsed.contains(flag) ? FlutterOptionSupport.supported : .unsupported) : .unknown)
        })
        return FlutterCapabilityProbe(
            executable: executable,
            sdkVersion: sdkVersion,
            target: target,
            helpArguments: helpArguments,
            exitCode: result?.exitCode,
            stdout: stdout,
            stderr: stderr,
            parsedFlags: parsed,
            requestedFlags: requested,
            states: states,
            cacheHit: cached != nil
        )
    }

    static func requestedOptions(for config: BuildConfiguration) -> [String] {
        var requested = ["--\(config.buildMode)"]
        if let flavor = config.flavor, !flavor.isEmpty { requested.append("--flavor") }
        if !config.buildName.isEmpty { requested.append("--build-name") }
        if !config.buildNumber.isEmpty { requested.append("--build-number") }
        if config.defines.contains(where: { !$0.key.isEmpty }) { requested.append("--dart-define") }
        if let file = config.defineFile, !file.isEmpty { requested.append("--dart-define-from-file") }
        if config.obfuscate { requested.append("--obfuscate") }
        if let split = config.splitDebugInfo, !split.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { requested.append("--split-debug-info") }
        if config.treeShakeIcons { requested.append("--tree-shake-icons") }
        if config.platform == .androidAPK && config.splitPerABI { requested.append("--split-per-abi") }
        if config.platform == .iOSIPA, let plist = config.exportOptionsPlist, !plist.isEmpty { requested.append("--export-options-plist") }
        return Array(Set(requested)).sorted()
    }

    private static func log(_ probe: FlutterCapabilityProbe) {
        let command = ([probe.executable.path] + probe.helpArguments).joined(separator: " ")
        flutterCapabilityLogger.debug("Flutter capability probe executable=\(probe.executable.path, privacy: .public) sdk=\(probe.sdkVersion, privacy: .public) help=\(command, privacy: .public) exit=\(probe.exitCode.map { String($0) } ?? "unknown", privacy: .public) cacheHit=\(probe.cacheHit, privacy: .public) parsed=\(probe.parsedFlags.sorted().joined(separator: ","), privacy: .public) requested=\(probe.requestedFlags.joined(separator: ","), privacy: .public) states=\(probe.states.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: ","), privacy: .public) complete=\(probe.isComplete, privacy: .public)")
        flutterCapabilityLogger.debug("Flutter capability stdout:\n\(probe.stdout, privacy: .public)")
        flutterCapabilityLogger.debug("Flutter capability stderr:\n\(probe.stderr, privacy: .public)")
    }
}

// MARK: - Dart Entrypoint Discovery & Validation

struct DartEntrypointDetector: Sendable {
    private static let excludedDirectoryNames: Set<String> = [
        ".dart_tool",
        "build",
        ".git",
        ".fvm",
        ".symlinks",
        ".plugin_symlinks",
        "Pods",
        "ephemeral",
        "node_modules",
        "ios",
        "android",
        "macos",
        "web",
        "linux",
        "windows"
    ]

    private static func canonicalFilePath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            path = String(path.dropFirst("/private".count))
        } else if path.hasPrefix("/private/tmp/") {
            path = String(path.dropFirst("/private".count))
        }
        return path.precomposedStringWithCanonicalMapping
    }

    func discoverWithDiagnostics(project: URL) -> DartEntrypointDiscoveryResult {
        var result = DartEntrypointDiscoveryResult()
        let fm = FileManager.default
        let canonicalProjectPath = Self.canonicalFilePath(project)

        let libURL = project.appendingPathComponent("lib", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: libURL.path, isDirectory: &isDir), isDir.boolValue else {
            result.errors.append("The project's lib/ directory is missing.")
            return result
        }

        let canonicalLibURL = libURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalLibPath = Self.canonicalFilePath(libURL)
        guard canonicalLibPath == canonicalProjectPath || canonicalLibPath.hasPrefix(canonicalProjectPath + "/") else {
            result.errors.append("The project's lib/ directory resolves outside the project root.")
            return result
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        guard let enumerator = fm.enumerator(
            at: canonicalLibURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            result.errors.append("Could not enumerate files in lib/.")
            return result
        }

        var visitedDirectories: Set<String> = [canonicalLibPath]
        var detected: [DetectedEntrypoint] = []

        while let item = enumerator.nextObject() as? URL {
            let itemName = item.lastPathComponent
            let itemIsDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if itemName.hasPrefix(".") || Self.excludedDirectoryNames.contains(itemName) {
                if itemIsDir { enumerator.skipDescendants() }
                continue
            }

            let resolvedURL = item.resolvingSymlinksInPath().standardizedFileURL
            let resolvedPath = Self.canonicalFilePath(item)
            var resolvedIsDir: ObjCBool = false
            let resolvedExists = fm.fileExists(atPath: resolvedURL.path, isDirectory: &resolvedIsDir)

            // Reject symlinks escaping the project root or lib root
            guard resolvedPath == canonicalLibPath || resolvedPath.hasPrefix(canonicalLibPath + "/") else {
                if itemIsDir { enumerator.skipDescendants() }
                result.warnings.append("Skipped symlink escaping project lib/ directory: \(item.lastPathComponent)")
                continue
            }

            guard resolvedExists else {
                continue
            }

            if resolvedIsDir.boolValue {
                if itemIsDir, !visitedDirectories.insert(resolvedPath).inserted {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard item.pathExtension.lowercased() == "dart" else { continue }

            let relativeSubpath: String
            if resolvedPath.hasPrefix(canonicalLibPath + "/") {
                let start = resolvedPath.index(resolvedPath.startIndex, offsetBy: canonicalLibPath.count + 1)
                relativeSubpath = String(resolvedPath[start...])
            } else {
                continue
            }

            let relativePath = ("lib/" + relativeSubpath.replacingOccurrences(of: "\\", with: "/")).precomposedStringWithCanonicalMapping

            guard let data = try? Data(contentsOf: resolvedURL) else {
                result.warnings.append("Could not read \(relativePath).")
                continue
            }

            guard let source = String(data: data, encoding: .utf8) else {
                let filename = item.deletingPathExtension().lastPathComponent.lowercased()
                if filename == "main" || filename.hasPrefix("main_") || filename.hasSuffix("_main") {
                    detected.append(
                        DetectedEntrypoint(
                            path: relativePath,
                            confidence: .potential,
                            signature: nil,
                            explanation: "File encoding could not be decoded as UTF-8; marked as potential entrypoint based on filename."
                        )
                    )
                }
                continue
            }

            let inspection = DartSourceInspector.inspect(source: source, filename: item.lastPathComponent)
            switch inspection {
            case .confirmed(let signature):
                detected.append(
                    DetectedEntrypoint(
                        path: relativePath,
                        confidence: .confirmed,
                        signature: signature,
                        explanation: "Top-level main() declaration verified."
                    )
                )
            case .potential(let reason):
                detected.append(
                    DetectedEntrypoint(
                        path: relativePath,
                        confidence: .potential,
                        signature: nil,
                        explanation: reason
                    )
                )
            case .notEntrypoint:
                break
            }
        }

        detected.sort { left, right in
            if left.path == right.path { return false }
            if left.path == "lib/main.dart" { return true }
            if right.path == "lib/main.dart" { return false }
            if left.confidence != right.confidence {
                return left.confidence == .confirmed
            }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }

        result.entrypoints = detected
        if detected.isEmpty {
            result.warnings.append("No Dart files with a top-level main() function were found under lib/.")
        }
        return result
    }

    func discoverEntrypoints(project: URL) -> [DetectedEntrypoint] {
        discoverWithDiagnostics(project: project).entrypoints
    }

    func discover(project: URL) -> [String] {
        discoverWithDiagnostics(project: project).entrypoints.map(\.path)
    }
}

typealias DartEntrypointDiscovery = DartEntrypointDetector

// MARK: - Lightweight Dart Source Inspector

enum DartEntrypointInspectionResult: Equatable, Sendable {
    case confirmed(signature: String)
    case potential(reason: String)
    case notEntrypoint
}

struct DartSourceInspector: Sendable {
    static func inspect(source: String, filename: String = "") -> DartEntrypointInspectionResult {
        let stripped = stripCommentsAndStrings(from: source)
        let topLevel = extractTopLevelCode(from: stripped.code)

        // If syntax had unclosed strings/comments or unbalanced braces, we cannot confidently analyze it:
        if !stripped.cleanlyTerminated || !topLevel.balancedBraces {
            let hasMainToken = stripped.code.range(of: #"\bmain\s*\("#, options: .regularExpression) != nil
            let baseName = (filename as NSString).deletingPathExtension.lowercased()
            let isMainNamed = baseName == "main" || baseName.hasPrefix("main_") || baseName.hasSuffix("_main") || baseName.hasPrefix("main-")
            if hasMainToken || isMainNamed {
                return .potential(reason: "Dart syntax could not be confidently analyzed; marked as a potential entrypoint.")
            }
            return .notEntrypoint
        }

        if let signature = findMainSignature(in: topLevel.topLevelText) {
            return .confirmed(signature: signature)
        }

        return .notEntrypoint
    }

    /// Strips `//` line comments, `/* ... */` block comments, and single/triple/raw string literals,
    /// replacing their contents with spaces so top-level token positions and line structure remain intact.
    private static func stripCommentsAndStrings(from source: String) -> (code: String, cleanlyTerminated: Bool) {
        let scalars = Array(source.unicodeScalars)
        let count = scalars.count
        var output = String.UnicodeScalarView()
        output.reserveCapacity(count)

        var i = 0
        var cleanlyTerminated = true

        while i < count {
            let c = scalars[i]

            // Check for comments
            if c == "/" && i + 1 < count {
                let next = scalars[i + 1]
                // Single-line comment //
                if next == "/" {
                    output.append(" ")
                    output.append(" ")
                    i += 2
                    while i < count && scalars[i] != "\n" && scalars[i] != "\r" {
                        output.append(" ")
                        i += 1
                    }
                    continue
                }
                // Block comment /* ... */ (Dart supports nested block comments)
                if next == "*" {
                    output.append(" ")
                    output.append(" ")
                    i += 2
                    var depth = 1
                    while i < count && depth > 0 {
                        if scalars[i] == "/" && i + 1 < count && scalars[i + 1] == "*" {
                            depth += 1
                            output.append(" ")
                            output.append(" ")
                            i += 2
                        } else if scalars[i] == "*" && i + 1 < count && scalars[i + 1] == "/" {
                            depth -= 1
                            output.append(" ")
                            output.append(" ")
                            i += 2
                        } else {
                            if scalars[i] == "\n" || scalars[i] == "\r" {
                                output.append(scalars[i])
                            } else {
                                output.append(" ")
                            }
                            i += 1
                        }
                    }
                    if depth > 0 {
                        cleanlyTerminated = false
                    }
                    continue
                }
            }

            // Check for raw strings: r'...', r"...", r'''...''', r"""..."""
            let isRawPrefix = (c == "r" || c == "R") && i + 1 < count && (scalars[i + 1] == "'" || scalars[i + 1] == "\"")
            if isRawPrefix || c == "'" || c == "\"" {
                let quoteIndex = isRawPrefix ? i + 1 : i
                let quoteChar = scalars[quoteIndex]
                if isRawPrefix {
                    output.append(" ")
                }
                let isTriple = (quoteIndex + 2 < count && scalars[quoteIndex + 1] == quoteChar && scalars[quoteIndex + 2] == quoteChar)
                if isTriple {
                    output.append(" ")
                    output.append(" ")
                    output.append(" ")
                    i = quoteIndex + 3
                    var closed = false
                    while i < count {
                        if !isRawPrefix && scalars[i] == "\\" {
                            output.append(" ")
                            if i + 1 < count {
                                output.append(scalars[i + 1] == "\n" ? "\n" : " ")
                                i += 2
                            } else {
                                i += 1
                            }
                            continue
                        }
                        if i + 2 < count && scalars[i] == quoteChar && scalars[i + 1] == quoteChar && scalars[i + 2] == quoteChar {
                            output.append(" ")
                            output.append(" ")
                            output.append(" ")
                            i += 3
                            closed = true
                            break
                        }
                        output.append(scalars[i] == "\n" ? "\n" : " ")
                        i += 1
                    }
                    if !closed {
                        cleanlyTerminated = false
                    }
                    continue
                } else {
                    output.append(" ")
                    i = quoteIndex + 1
                    var closed = false
                    while i < count {
                        if !isRawPrefix && scalars[i] == "\\" {
                            output.append(" ")
                            if i + 1 < count {
                                i += 2
                            } else {
                                i += 1
                            }
                            continue
                        }
                        if scalars[i] == quoteChar {
                            output.append(" ")
                            i += 1
                            closed = true
                            break
                        }
                        if scalars[i] == "\n" || scalars[i] == "\r" {
                            // Unterminated single-line string literal
                            output.append(scalars[i])
                            i += 1
                            break
                        }
                        output.append(" ")
                        i += 1
                    }
                    if !closed {
                        cleanlyTerminated = false
                    }
                    continue
                }
            }

            output.append(c)
            i += 1
        }

        return (String(output), cleanlyTerminated)
    }

    /// Replaces everything inside `{ ... }` blocks (depth >= 1) with `{}` at top-level so nested methods
    /// inside classes/extensions/functions cannot be mistaken for top-level declarations.
    private static func extractTopLevelCode(from code: String) -> (topLevelText: String, balancedBraces: Bool) {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(code.unicodeScalars.count)
        var depth = 0
        var balanced = true

        for scalar in code.unicodeScalars {
            if scalar == "{" {
                if depth == 0 {
                    result.append("{")
                }
                depth += 1
            } else if scalar == "}" {
                depth -= 1
                if depth < 0 {
                    balanced = false
                    depth = 0
                } else if depth == 0 {
                    result.append("}")
                }
            } else if depth == 0 {
                result.append(scalar)
            } else if scalar == "\n" {
                result.append("\n")
            }
        }

        if depth != 0 {
            balanced = false
        }
        return (String(result), balanced)
    }

    /// Matches top-level Dart `main` function declarations:
    /// - `void main(...) {` / `void main(...) async {` / `void main(...) =>`
    /// - `Future<void> main(...) async {`
    /// - `FutureOr<void> main(...) async {`
    /// - `Future main(...) async {`
    /// - `dynamic main(...) {`
    /// - `main(...) {` / `main(...) async {`
    private static func findMainSignature(in topLevelText: String) -> String? {
        let pattern = #"(?:^|[;}\n\r]|\))\s*(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\s*\([^)]*\))?\s*)*(?:(?:external\s+)?(?:(?:void|dynamic|Future\s*<\s*void\s*>|Future\s*<\s*dynamic\s*>|FutureOr\s*<\s*void\s*>|FutureOr\s*<\s*dynamic\s*>|Future|FutureOr)\s+)?)main\s*\([^)]*\)\s*(?:async\s*\*?\s*|sync\s*\*\s*)?(?:\{|=>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let ns = topLevelText as NSString
        let matches = regex.matches(in: topLevelText, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let raw = ns.substring(with: match.range)
            // Ensure this is not a control flow statement or call like `return main()` or `= main()`
            let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";})")))
            if trimmed.hasPrefix("return ") || trimmed.hasPrefix("await ") {
                continue
            }
            let normalized = trimmed
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
        return nil
    }
}

// MARK: - Xcode Project, Workspace & Scheme Parsers

struct XcodeBuildListResponse: Decodable, Sendable {
    struct ContainerInfo: Decodable, Sendable {
        var name: String?
        var schemes: [String]?
        var configurations: [String]?
        var targets: [String]?
    }
    var project: ContainerInfo?
    var workspace: ContainerInfo?
}

struct ParsedXCScheme: Sendable, Equatable {
    var name: String
    var launchConfiguration: String?
    var testConfiguration: String?
    var profileConfiguration: String?
    var analyzeConfiguration: String?
    var archiveConfiguration: String?
    var targetNames: [String] = []
    var appTargetNames: [String] = []
    var archiveTargets: [XCSchemeBuildableReference] = []
    var testOnlyTargets: Bool = false
    var isValidXML: Bool = true

    var allReferencedConfigurations: [String] {
        var seen = Set<String>()
        return [launchConfiguration, archiveConfiguration, profileConfiguration, testConfiguration, analyzeConfiguration]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct XCSchemeBuildableReference: Sendable, Equatable {
    var blueprintIdentifier: String
    var blueprintName: String
    var buildableName: String
    var referencedContainer: String
    var buildForArchiving: Bool
}

final class XCSchemeXMLParserDelegate: NSObject, XMLParserDelegate {
    var launchConfiguration: String?
    var testConfiguration: String?
    var profileConfiguration: String?
    var analyzeConfiguration: String?
    var archiveConfiguration: String?
    var targetNames: [String] = []
    var appTargetNames: [String] = []
    var archiveTargets: [XCSchemeBuildableReference] = []
    var hasTestEntries = false
    private var currentBuildForRunning = false
    private var currentBuildForArchiving = false
    private var currentBuildForArchivingEntry = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "BuildActionEntry":
            currentBuildForRunning = attributeDict["buildForRunning"] == "YES"
            currentBuildForArchiving = attributeDict["buildForArchiving"] == "YES"
            currentBuildForArchivingEntry = currentBuildForArchiving
        case "BuildableReference":
            let blueprintName = attributeDict["BlueprintName"] ?? ""
            let buildableName = attributeDict["BuildableName"] ?? ""
            if !blueprintName.isEmpty && !targetNames.contains(blueprintName) {
                targetNames.append(blueprintName)
            }
            if buildableName.hasSuffix(".app") || ((currentBuildForRunning || currentBuildForArchiving) && !buildableName.hasSuffix(".xctest") && !blueprintName.hasSuffix("Tests")) {
                let candidate = blueprintName.isEmpty ? buildableName : blueprintName
                if !candidate.isEmpty && !appTargetNames.contains(candidate) {
                    appTargetNames.append(candidate)
                }
            }
            if buildableName.hasSuffix(".xctest") || blueprintName.hasSuffix("Tests") {
                hasTestEntries = true
            }
            if currentBuildForArchivingEntry {
                delegateArchiveReference(attributeDict)
            }
        case "LaunchAction":
            launchConfiguration = attributeDict["buildConfiguration"]
        case "TestAction":
            testConfiguration = attributeDict["buildConfiguration"]
        case "ProfileAction":
            profileConfiguration = attributeDict["buildConfiguration"]
        case "AnalyzeAction":
            analyzeConfiguration = attributeDict["buildConfiguration"]
        case "ArchiveAction":
            archiveConfiguration = attributeDict["buildConfiguration"]
        default:
            break
        }
    }

    private func delegateArchiveReference(_ attributes: [String: String]) {
        archiveTargets.append(XCSchemeBuildableReference(
            blueprintIdentifier: attributes["BlueprintIdentifier"] ?? "",
            blueprintName: attributes["BlueprintName"] ?? "",
            buildableName: attributes["BuildableName"] ?? "",
            referencedContainer: attributes["ReferencedContainer"] ?? "",
            buildForArchiving: true
        ))
    }
}

struct XCSchemeParser: Sendable {
    static func parse(url: URL) -> ParsedXCScheme {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ParsedXCScheme(name: name, isValidXML: false)
        }
        let delegate = XCSchemeXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let success = parser.parse()
        let testOnly = delegate.appTargetNames.isEmpty && delegate.hasTestEntries
        return ParsedXCScheme(
            name: name,
            launchConfiguration: delegate.launchConfiguration,
            testConfiguration: delegate.testConfiguration,
            profileConfiguration: delegate.profileConfiguration,
            analyzeConfiguration: delegate.analyzeConfiguration,
            archiveConfiguration: delegate.archiveConfiguration,
            targetNames: delegate.targetNames,
            appTargetNames: delegate.appTargetNames,
            archiveTargets: delegate.archiveTargets,
            testOnlyTargets: testOnly,
            isValidXML: success
        )
    }
}

final class XCWorkspaceXMLParserDelegate: NSObject, XMLParserDelegate {
    var referencedLocations: [String] = []
    var sawWorkspaceElement = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "Workspace" {
            sawWorkspaceElement = true
        } else if elementName == "FileRef", let location = attributeDict["location"] {
            referencedLocations.append(location)
        }
    }
}

struct XCWorkspaceParser: Sendable {
    struct Result: Sendable {
        var isValid: Bool
        var projectPaths: [String]
    }

    static func parse(workspaceURL: URL) -> Result {
        let dataURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            // A directory without contents.xcworkspacedata may be a minimal test fixture workspace
            return Result(isValid: true, projectPaths: [])
        }
        guard let data = try? Data(contentsOf: dataURL), !data.isEmpty else {
            return Result(isValid: false, projectPaths: [])
        }
        let delegate = XCWorkspaceXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let ok = parser.parse() && delegate.sawWorkspaceElement
        let projects = delegate.referencedLocations.compactMap { loc -> String? in
            let cleaned = loc
                .replacingOccurrences(of: "group:", with: "")
                .replacingOccurrences(of: "container:", with: "")
                .replacingOccurrences(of: "self:", with: "")
            guard cleaned.hasSuffix(".xcodeproj") else { return nil }
            return cleaned
        }
        return Result(isValid: ok, projectPaths: projects)
    }
}

struct ParsedPBXProj: Sendable {
    struct Target: Sendable, Equatable {
        var identifier: String
        var name: String
        var productType: String
        var buildConfigurations: [String]
    }
    var buildConfigurations: [String] = []
    var targets: [String] = []
    var appTargets: [String] = []
    var targetByIdentifier: [String: Target] = [:]
    var isValid: Bool = true
}

struct PBXProjParser: Sendable {
    static func parse(projectURL: URL) -> ParsedPBXProj {
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        guard FileManager.default.fileExists(atPath: pbxprojURL.path) else {
            return ParsedPBXProj(isValid: true)
        }
        guard let data = try? Data(contentsOf: pbxprojURL), !data.isEmpty else {
            return ParsedPBXProj(isValid: false)
        }

        // 1. Primary parser: PropertyListSerialization natively parses OpenStep/XML project.pbxproj files on macOS.
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let objects = plist["objects"] as? [String: Any] {
            var configs = Set<String>()
            var targets: [String] = []
            var appTargets: [String] = []
            var targetsByIdentifier: [String: ParsedPBXProj.Target] = [:]

            for (identifier, value) in objects {
                guard let dict = value as? [String: Any], let isa = dict["isa"] as? String else { continue }
                if isa == "XCBuildConfiguration", let name = dict["name"] as? String, !name.isEmpty {
                    configs.insert(name)
                } else if isa == "PBXNativeTarget", let name = dict["name"] as? String, !name.isEmpty {
                    if !targets.contains(name) { targets.append(name) }
                    let productType = dict["productType"] as? String ?? ""
                    let configurationListID = dict["buildConfigurationList"] as? String
                    let configurationIDs = (configurationListID.flatMap { objects[$0] as? [String: Any] }?["buildConfigurations"] as? [String]) ?? []
                    let targetConfigurations = configurationIDs.compactMap { id -> String? in
                        (objects[id] as? [String: Any])?["name"] as? String
                    }
                    targetsByIdentifier[identifier] = ParsedPBXProj.Target(
                        identifier: identifier,
                        name: name,
                        productType: productType,
                        buildConfigurations: targetConfigurations
                    )
                    if productType == "com.apple.product-type.application" {
                        if !appTargets.contains(name) { appTargets.append(name) }
                    }
                }
            }

            return ParsedPBXProj(
                buildConfigurations: configs.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                targets: targets.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                appTargets: appTargets.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                targetByIdentifier: targetsByIdentifier,
                isValid: true
            )
        }

        return ParsedPBXProj(isValid: false)
    }
}

// MARK: - iOS Flavor Detector

struct IOSFlavorDetector: Sendable {
    struct XcodeContainerSelection: Sendable {
        var workspaceURL: URL?
        var projectURL: URL?
        var workspaceValid: Bool = true
    }

    var xcodebuildExecutable: URL

    init(xcodebuildExecutable: URL = URL(fileURLWithPath: "/usr/bin/xcodebuild")) {
        self.xcodebuildExecutable = xcodebuildExecutable
    }

    static func locateXcodeContainer(in projectRoot: URL) -> XcodeContainerSelection {
        let iosDir = projectRoot.appendingPathComponent("ios", isDirectory: true)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: iosDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return XcodeContainerSelection()
        }

        let workspaces = items
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { a, b in
                if a.lastPathComponent == "Runner.xcworkspace" { return true }
                if b.lastPathComponent == "Runner.xcworkspace" { return false }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }

        let xcodeprojs = items
            .filter { $0.pathExtension == "xcodeproj" && $0.lastPathComponent != "Pods.xcodeproj" }
            .sorted { a, b in
                if a.lastPathComponent == "Runner.xcodeproj" { return true }
                if b.lastPathComponent == "Runner.xcodeproj" { return false }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }

        let selectedWorkspace = workspaces.first
        var selectedProject = xcodeprojs.first
        var workspaceValid = true

        if let ws = selectedWorkspace {
            let parsedWS = XCWorkspaceParser.parse(workspaceURL: ws)
            workspaceValid = parsedWS.isValid
            if let referenced = parsedWS.projectPaths.first(where: { !$0.contains("Pods.xcodeproj") }) {
                let candidate = iosDir.appendingPathComponent(referenced)
                if fm.fileExists(atPath: candidate.path) {
                    selectedProject = candidate
                }
            }
        }

        return XcodeContainerSelection(
            workspaceURL: selectedWorkspace,
            projectURL: selectedProject,
            workspaceValid: workspaceValid
        )
    }

    func discover(project: URL, executor: any CLIExecuting) async -> FlavorDiscoveryDiagnostics {
        let startedAt = Date()
        var diagnostics = FlavorDiscoveryDiagnostics(platform: .iOSIPA)
        let fm = FileManager.default
        let iosDir = project.appendingPathComponent("ios", isDirectory: true)
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: iosDir.path, isDirectory: &isDir), isDir.boolValue else {
            let msg = "The iOS project folder (ios/) is missing."
            diagnostics.errors.append(msg)
            diagnostics.emptyStateExplanation = msg
            return diagnostics
        }

        let container = Self.locateXcodeContainer(in: project)
        guard container.workspaceURL != nil || container.projectURL != nil else {
            let msg = "No Xcode workspace (.xcworkspace) or project (.xcodeproj) was found in ios/."
            diagnostics.errors.append(msg)
            diagnostics.emptyStateExplanation = msg
            return diagnostics
        }

        if let ws = container.workspaceURL {
            diagnostics.containerPath = "ios/\(ws.lastPathComponent)"
        } else if let proj = container.projectURL {
            diagnostics.containerPath = "ios/\(proj.lastPathComponent)"
        }
        if let proj = container.projectURL {
            diagnostics.projectPath = "ios/\(proj.lastPathComponent)"
        } else {
            let message = "The workspace was found, but its Flutter application .xcodeproj could not be resolved. Scheme discovery needs the app project to verify target product types."
            diagnostics.errors.append(message)
            diagnostics.emptyStateExplanation = message
        }

        if !container.workspaceValid, let ws = container.workspaceURL {
            let msg = "The Xcode workspace 'ios/\(ws.lastPathComponent)' contains corrupted or invalid workspace data."
            diagnostics.errors.append(msg)
        }

        // 1. Inspect project.pbxproj if available
        var pbxproj = ParsedPBXProj(isValid: true)
        if let projURL = container.projectURL {
            pbxproj = PBXProjParser.parse(projectURL: projURL)
            if !pbxproj.isValid {
                diagnostics.errors.append("The Xcode project 'ios/\(projURL.lastPathComponent)/project.pbxproj' is invalid or corrupted.")
            }
        }

        // Shared app-project schemes are the portable source for Flutter archives.
        // Workspace schemes commonly include every CocoaPods and plugin dependency.
        let diskSchemes = Self.discoverSharedSchemesOnDisk(workspaceURL: container.workspaceURL, projectURL: container.projectURL)
        diagnostics.localSchemes = Self.discoverLocalSchemesOnDisk(projectURL: container.projectURL)
        for (_, scheme) in diskSchemes where !scheme.isValidXML {
            diagnostics.warnings.append("Shared scheme file '\(scheme.name).xcscheme' contains invalid XML.")
        }
        // project.pbxproj gives us the real application target product types and
        // ArchiveAction configurations without launching Xcode.
        let allConfigs = pbxproj.buildConfigurations
        diagnostics.discoveredBuildConfigurations = allConfigs
        diagnostics.discoveredTargets = pbxproj.targets

        var classifiedSchemes: [DiscoveredXcodeScheme] = []
        var appSchemes: [String: ParsedXCScheme] = [:]
        for (name, scheme) in diskSchemes {
            guard scheme.isValidXML, let projectURL = container.projectURL,
                  let archive = scheme.archiveConfiguration,
                  allConfigs.contains(archive) else { continue }
            let expectedContainer = "container:\(projectURL.lastPathComponent)"
            let resolvableApplications = scheme.archiveTargets.compactMap { reference -> ParsedPBXProj.Target? in
                guard reference.referencedContainer == expectedContainer,
                      let target = pbxproj.targetByIdentifier[reference.blueprintIdentifier],
                      target.productType == "com.apple.product-type.application",
                      target.name == reference.blueprintName,
                      target.buildConfigurations.contains(archive) else { return nil }
                return target
            }
            guard !resolvableApplications.isEmpty else { continue }
            var resolvedScheme = scheme
            resolvedScheme.targetNames = Array(Set(resolvableApplications.map(\.name))).sorted()
            appSchemes[name] = resolvedScheme
            if resolvableApplications.count > 1 {
                diagnostics.warnings.append("Scheme '\(name)' archives multiple application targets: \(resolvedScheme.targetNames.joined(separator: ", ")).")
            }
        }
        for (name, _) in diskSchemes where appSchemes[name] == nil {
            let reason: String
            if let scheme = diskSchemes[name], !scheme.isValidXML {
                reason = "Scheme '\(name)' contains invalid XML and is excluded from application archive schemes."
            } else if let archive = diskSchemes[name]?.archiveConfiguration, !allConfigs.contains(archive) {
                reason = "Scheme '\(name)' ArchiveAction references missing build configuration '\(archive)' in the app project."
            } else {
                reason = "Scheme '\(name)' is excluded because its ArchiveAction does not resolve to an application target and valid archive configuration in the app project."
            }
            diagnostics.warnings.append(reason)
            if let scheme = diskSchemes[name] {
                classifiedSchemes.append(DiscoveredXcodeScheme(
                    name: name,
                    confidence: .invalidConfiguration,
                    buildConfigurations: scheme.allReferencedConfigurations,
                    launchConfiguration: scheme.launchConfiguration,
                    archiveConfiguration: scheme.archiveConfiguration,
                    profileConfiguration: scheme.profileConfiguration,
                    testConfiguration: scheme.testConfiguration,
                    analyzeConfiguration: scheme.analyzeConfiguration,
                    targetNames: scheme.targetNames,
                    isSharedOnDisk: true,
                    explanation: reason
                ))
            }
        }
        let flavorConfigMap = Self.extractFlavorConfigurationGroups(from: allConfigs)
        var claimedFlavorSuffixes = Set<String>()
        var selectableFlavors: [DetectedFlavor] = []

        let orderedSchemeNames = appSchemes.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for schemeName in orderedSchemeNames {
            let diskScheme = appSchemes[schemeName]

            let classification = Self.classifyScheme(
                schemeName: schemeName,
                diskScheme: diskScheme,
                isListedByXcode: false,
                xcodebuildSucceeded: false,
                allConfigs: allConfigs,
                flavorConfigMap: flavorConfigMap,
                claimedFlavorSuffixes: &claimedFlavorSuffixes,
                warnings: &diagnostics.warnings
            )
            classifiedSchemes.append(classification.scheme)
            if let flavor = classification.flavor {
                selectableFlavors.append(flavor)
            }
        }

        // Check for orphaned flavor build configurations (e.g. Release-prod exists in pbxproj, but no scheme for prod)
        for (lowerSuffix, group) in flavorConfigMap.sorted(by: { $0.key < $1.key }) {
            guard !claimedFlavorSuffixes.contains(lowerSuffix) else { continue }
            // Check if any scheme matches case-insensitively
            guard !orderedSchemeNames.contains(where: { $0.lowercased() == lowerSuffix }) else { continue }

            let hasRelease = group.configs.contains { Self.parseBuildConfig($0)?.mode.lowercased() == "release" }
            let configList = group.configs.sorted()
            diagnostics.warnings.append(
                "Build configuration '\(configList.joined(separator: ", "))' exists for '\(group.displaySuffix)', but no matching shared Xcode scheme was found."
            )
            classifiedSchemes.append(
                DiscoveredXcodeScheme(
                    name: group.displaySuffix,
                    confidence: .invalidConfiguration,
                    buildConfigurations: configList,
                    isSharedOnDisk: false,
                    isListedByXcodebuild: false,
                    explanation: "Build configuration \(configList.joined(separator: ", ")) has no matching shared Xcode scheme."
                )
            )
            // If no schemes were discovered at all, expose as a potential flavor so the user isn't stuck with a hidden configuration
            if selectableFlavors.isEmpty && hasRelease && diagnostics.errors.isEmpty {
                selectableFlavors.append(
                    DetectedFlavor(
                        name: group.displaySuffix,
                        source: "Xcode build configuration (\(configList.joined(separator: ", "))) — missing shared scheme",
                        verified: false,
                        confidence: .potentialFlavor,
                        schemeName: nil,
                        buildConfigurations: configList,
                        explanation: "Inferred from \(configList.joined(separator: ", ")) because no shared Xcode scheme was found. Share the scheme in Xcode."
                    )
                )
            }
        }

        diagnostics.discoveredSchemes = classifiedSchemes
        diagnostics.flavors = selectableFlavors
        diagnostics.discoveryDurationSeconds = Date().timeIntervalSince(startedAt)

        // Determine clear empty state explanation when no flavors are available
        if selectableFlavors.isEmpty {
            if let firstError = diagnostics.errors.first {
                diagnostics.emptyStateExplanation = firstError
            } else if classifiedSchemes.contains(where: { $0.name.caseInsensitiveCompare("Runner") == .orderedSame && $0.confidence == .ordinaryScheme }) && classifiedSchemes.allSatisfy({ !$0.confidence.isSelectableFlavor }) {
                if classifiedSchemes.contains(where: { $0.confidence == .invalidConfiguration }) {
                    diagnostics.emptyStateExplanation = "Flavor configurations were found with errors or missing schemes. Review Discovery Diagnostics."
                } else {
                    diagnostics.emptyStateExplanation = "Only the default 'Runner' Xcode scheme was found (no flavor-specific schemes or Release-<flavor> configurations). Use 'No Flavor' for standard builds."
                }
            } else if classifiedSchemes.isEmpty {
                diagnostics.emptyStateExplanation = "No shared Xcode schemes were found in \(diagnostics.containerPath ?? "ios/"). Mark schemes as 'Shared' in Xcode."
            } else {
                diagnostics.emptyStateExplanation = "No valid Flutter iOS flavors were detected. Review Discovery Diagnostics for details."
            }
        }

        return diagnostics
    }

    private struct FlavorConfigGroup {
        var displaySuffix: String
        var configs: [String]
    }

    private static func parseBuildConfig(_ config: String) -> (mode: String, suffix: String)? {
        let modes = ["Debug", "Release", "Profile"]
        for mode in modes {
            if config.count > mode.count + 1 {
                let prefix = String(config.prefix(mode.count))
                let sepIndex = config.index(config.startIndex, offsetBy: mode.count)
                let sep = config[sepIndex]
                if prefix.caseInsensitiveCompare(mode) == .orderedSame && (sep == "-" || sep == "_" || sep == " ") {
                    let suffix = String(config[config.index(after: sepIndex)...]).trimmingCharacters(in: .whitespaces)
                    if !suffix.isEmpty {
                        return (mode, suffix)
                    }
                }
                let tail = String(config.suffix(mode.count))
                let tailSepIndex = config.index(config.endIndex, offsetBy: -(mode.count + 1))
                let tailSep = config[tailSepIndex]
                if tail.caseInsensitiveCompare(mode) == .orderedSame && (tailSep == "-" || tailSep == "_" || tailSep == " ") {
                    let prefixFlavor = String(config[..<tailSepIndex]).trimmingCharacters(in: .whitespaces)
                    if !prefixFlavor.isEmpty {
                        return (mode, prefixFlavor)
                    }
                }
            }
        }
        return nil
    }

    private static func isStandardBaseConfiguration(_ config: String) -> Bool {
        let lower = config.lowercased()
        return lower == "debug" || lower == "release" || lower == "profile"
    }

    private static func extractFlavorConfigurationGroups(from configs: [String]) -> [String: FlavorConfigGroup] {
        var map: [String: FlavorConfigGroup] = [:]
        for config in configs {
            guard let parsed = parseBuildConfig(config) else { continue }
            let key = parsed.suffix.lowercased()
            if var existing = map[key] {
                existing.configs.append(config)
                map[key] = existing
            } else {
                map[key] = FlavorConfigGroup(displaySuffix: parsed.suffix, configs: [config])
            }
        }
        return map
    }

    private static func classifyScheme(
        schemeName: String,
        diskScheme: ParsedXCScheme?,
        isListedByXcode: Bool,
        xcodebuildSucceeded: Bool,
        allConfigs: [String],
        flavorConfigMap: [String: FlavorConfigGroup],
        claimedFlavorSuffixes: inout Set<String>,
        warnings: inout [String]
    ) -> (scheme: DiscoveredXcodeScheme, flavor: DetectedFlavor?) {
        // 1. Auxiliary / Pod / Test schemes
        let lowerName = schemeName.lowercased()
        if lowerName == "pods" || lowerName.hasPrefix("pods-") || schemeName.hasSuffix("Tests") || schemeName.hasSuffix("UITests") || (diskScheme?.testOnlyTargets == true) {
            let scheme = DiscoveredXcodeScheme(
                name: schemeName,
                confidence: .ordinaryScheme,
                buildConfigurations: diskScheme?.allReferencedConfigurations ?? [],
                launchConfiguration: diskScheme?.launchConfiguration,
                archiveConfiguration: diskScheme?.archiveConfiguration,
                profileConfiguration: diskScheme?.profileConfiguration,
                testConfiguration: diskScheme?.testConfiguration,
                analyzeConfiguration: diskScheme?.analyzeConfiguration,
                targetNames: diskScheme?.targetNames ?? [],
                isSharedOnDisk: diskScheme != nil,
                isListedByXcodebuild: isListedByXcode,
                explanation: "Test or dependency scheme; not a Flutter flavor."
            )
            return (scheme, nil)
        }

        // 2. Malformed .xcscheme XML on disk
        if let diskScheme, !diskScheme.isValidXML {
            let scheme = DiscoveredXcodeScheme(
                name: schemeName,
                confidence: .invalidConfiguration,
                isSharedOnDisk: true,
                isListedByXcodebuild: isListedByXcode,
                explanation: "Shared scheme file '\(schemeName).xcscheme' is corrupted or invalid XML."
            )
            return (scheme, nil)
        }

        let matchingSuffixGroup = flavorConfigMap[lowerName]
        if matchingSuffixGroup != nil {
            claimedFlavorSuffixes.insert(lowerName)
        }

        // 3. When we have a parsed .xcscheme on disk
        if let diskScheme {
            let referenced = diskScheme.allReferencedConfigurations
            for ref in referenced {
                if let parsed = parseBuildConfig(ref) {
                    claimedFlavorSuffixes.insert(parsed.suffix.lowercased())
                }
            }

            // Check if any referenced configuration is missing from allConfigs (when allConfigs is non-empty)
            if !allConfigs.isEmpty {
                let missing = referenced.filter { ref in !allConfigs.contains(ref) }
                if !missing.isEmpty {
                    let msg = "Scheme '\(schemeName)' references build configuration '\(missing.joined(separator: ", "))' which does not exist in the Xcode project."
                    warnings.append(msg)
                    let scheme = DiscoveredXcodeScheme(
                        name: schemeName,
                        confidence: .invalidConfiguration,
                        buildConfigurations: referenced,
                        launchConfiguration: diskScheme.launchConfiguration,
                        archiveConfiguration: diskScheme.archiveConfiguration,
                        profileConfiguration: diskScheme.profileConfiguration,
                        testConfiguration: diskScheme.testConfiguration,
                        analyzeConfiguration: diskScheme.analyzeConfiguration,
                        targetNames: diskScheme.targetNames,
                        isSharedOnDisk: true,
                        isListedByXcodebuild: isListedByXcode,
                        explanation: msg
                    )
                    return (scheme, nil)
                }
            }

            // Check for mismatch between scheme's Launch/Archive configurations and available flavor configurations
            let archiveCfg = diskScheme.archiveConfiguration ?? ""
            let launchCfg = diskScheme.launchConfiguration ?? ""
            let archiveParsed = parseBuildConfig(archiveCfg)
            let launchParsed = parseBuildConfig(launchCfg)

            // Mismatch case A: Launch and Archive point to different flavor suffixes (e.g., Debug-dev vs Release-prod or plain Release)
            if let lp = launchParsed, archiveParsed == nil && !archiveCfg.isEmpty {
                let msg = "Scheme '\(schemeName)' build configuration mismatch: Launch uses '\(launchCfg)' but Archive uses unflavored '\(archiveCfg)'."
                warnings.append(msg)
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .potentialFlavor,
                    buildConfigurations: referenced,
                    launchConfiguration: diskScheme.launchConfiguration,
                    archiveConfiguration: diskScheme.archiveConfiguration,
                    profileConfiguration: diskScheme.profileConfiguration,
                    testConfiguration: diskScheme.testConfiguration,
                    analyzeConfiguration: diskScheme.analyzeConfiguration,
                    targetNames: diskScheme.targetNames,
                    isSharedOnDisk: true,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: msg
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: "Xcode scheme (configuration mismatch: \(archiveCfg))",
                    verified: false,
                    confidence: .potentialFlavor,
                    schemeName: schemeName,
                    buildConfigurations: referenced,
                    explanation: msg
                )
                claimedFlavorSuffixes.insert(lp.suffix.lowercased())
                return (scheme, flavor)
            }

            if let lp = launchParsed, let ap = archiveParsed, lp.suffix.lowercased() != ap.suffix.lowercased() {
                let msg = "Scheme '\(schemeName)' build configuration mismatch: Launch uses '\(launchCfg)' (\(lp.suffix)) but Archive uses '\(archiveCfg)' (\(ap.suffix))."
                warnings.append(msg)
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .potentialFlavor,
                    buildConfigurations: referenced,
                    launchConfiguration: diskScheme.launchConfiguration,
                    archiveConfiguration: diskScheme.archiveConfiguration,
                    profileConfiguration: diskScheme.profileConfiguration,
                    testConfiguration: diskScheme.testConfiguration,
                    analyzeConfiguration: diskScheme.analyzeConfiguration,
                    targetNames: diskScheme.targetNames,
                    isSharedOnDisk: true,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: msg
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: "Xcode scheme (mismatched configurations)",
                    verified: false,
                    confidence: .potentialFlavor,
                    schemeName: schemeName,
                    buildConfigurations: referenced,
                    explanation: msg
                )
                return (scheme, flavor)
            }

            // Mismatch case B: Project has Release-<schemeName>, but scheme's ArchiveAction points to plain Release
            if let group = matchingSuffixGroup, archiveParsed == nil {
                let msg = "Scheme '\(schemeName)' uses '\(archiveCfg.isEmpty ? "Release" : archiveCfg)' for Archive even though '\(group.configs.joined(separator: ", "))' exists in the project."
                warnings.append(msg)
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .potentialFlavor,
                    buildConfigurations: referenced,
                    launchConfiguration: diskScheme.launchConfiguration,
                    archiveConfiguration: diskScheme.archiveConfiguration,
                    profileConfiguration: diskScheme.profileConfiguration,
                    testConfiguration: diskScheme.testConfiguration,
                    analyzeConfiguration: diskScheme.analyzeConfiguration,
                    targetNames: diskScheme.targetNames,
                    isSharedOnDisk: true,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: msg
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: "Xcode scheme (unlinked to Release-\(schemeName))",
                    verified: false,
                    confidence: .potentialFlavor,
                    schemeName: schemeName,
                    buildConfigurations: referenced,
                    explanation: msg
                )
                return (scheme, flavor)
            }

            // Does this scheme reference flavor-specific configurations (e.g. Release-dev, or custom scheme ProductionApp -> Release-production)?
            let hasFlavorConfig = referenced.contains { !isStandardBaseConfiguration($0) }
            if hasFlavorConfig {
                // Discovery already validated the scheme's ArchiveAction, target UUID,
                // application product type, and build configuration against the app project.
                let verified = diskScheme.isValidXML && diskScheme.archiveConfiguration != nil
                let confidence: FlavorConfidence = verified ? .confirmedFlavor : .potentialFlavor
                let configDesc = diskScheme.archiveConfiguration ?? referenced.first ?? "flavor configuration"
                let explanation = verified
                    ? "Verified Xcode scheme mapped to \(configDesc)."
                    : "Shared Xcode scheme mapped to \(configDesc) (not verified by xcodebuild)."
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: confidence,
                    buildConfigurations: referenced,
                    launchConfiguration: diskScheme.launchConfiguration,
                    archiveConfiguration: diskScheme.archiveConfiguration,
                    profileConfiguration: diskScheme.profileConfiguration,
                    testConfiguration: diskScheme.testConfiguration,
                    analyzeConfiguration: diskScheme.analyzeConfiguration,
                    targetNames: diskScheme.targetNames,
                    isSharedOnDisk: true,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: explanation
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: verified ? "Xcode scheme (\(configDesc))" : "Shared Xcode scheme (\(configDesc))",
                    verified: verified,
                    confidence: confidence,
                    schemeName: schemeName,
                    buildConfigurations: referenced,
                    explanation: explanation
                )
                return (scheme, flavor)
            }

            // Only standard Debug/Release/Profile configurations referenced in .xcscheme
            if schemeName.caseInsensitiveCompare("Runner") == .orderedSame {
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .ordinaryScheme,
                    buildConfigurations: referenced,
                    launchConfiguration: diskScheme.launchConfiguration,
                    archiveConfiguration: diskScheme.archiveConfiguration,
                    profileConfiguration: diskScheme.profileConfiguration,
                    testConfiguration: diskScheme.testConfiguration,
                    analyzeConfiguration: diskScheme.analyzeConfiguration,
                    targetNames: diskScheme.targetNames,
                    isSharedOnDisk: true,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: "Default Runner scheme using standard Debug/Profile/Release configurations."
                )
                return (scheme, nil)
            } else {
                let explanation = "Custom Xcode scheme '\(schemeName)' uses standard Debug/Release configurations without flavor-specific build configurations."
                if !flavorConfigMap.isEmpty {
                    warnings.append("Scheme '\(schemeName)' uses standard build configurations (\(referenced.joined(separator: ", "))) instead of a flavor-specific configuration.")
                }
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .potentialFlavor,
                    buildConfigurations: referenced,
                    launchConfiguration: diskScheme.launchConfiguration,
                    archiveConfiguration: diskScheme.archiveConfiguration,
                    profileConfiguration: diskScheme.profileConfiguration,
                    testConfiguration: diskScheme.testConfiguration,
                    analyzeConfiguration: diskScheme.analyzeConfiguration,
                    targetNames: diskScheme.targetNames,
                    isSharedOnDisk: true,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: explanation
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: "Xcode scheme (standard build configuration)",
                    verified: false,
                    confidence: .potentialFlavor,
                    schemeName: schemeName,
                    buildConfigurations: referenced,
                    explanation: explanation
                )
                return (scheme, flavor)
            }
        }

        // 4. Scheme was discovered via xcodebuild -list -json, without a local .xcscheme file parsed
        if let group = matchingSuffixGroup {
            let configs = group.configs.sorted()
            let hasRelease = configs.contains { parseBuildConfig($0)?.mode.lowercased() == "release" }
            if hasRelease {
                let explanation = "Verified via xcodebuild and matching \(configs.joined(separator: ", ")) build configuration."
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .confirmedFlavor,
                    buildConfigurations: configs,
                    isSharedOnDisk: false,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: explanation
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: "Xcode scheme (\(configs.joined(separator: ", ")))",
                    verified: true,
                    confidence: .confirmedFlavor,
                    schemeName: schemeName,
                    buildConfigurations: configs,
                    explanation: explanation
                )
                return (scheme, flavor)
            } else {
                let msg = "Scheme '\(schemeName)' has build configuration '\(configs.joined(separator: ", "))' but is missing 'Release-\(schemeName)'."
                warnings.append(msg)
                let scheme = DiscoveredXcodeScheme(
                    name: schemeName,
                    confidence: .potentialFlavor,
                    buildConfigurations: configs,
                    isSharedOnDisk: false,
                    isListedByXcodebuild: isListedByXcode,
                    explanation: msg
                )
                let flavor = DetectedFlavor(
                    name: schemeName,
                    source: "Xcode scheme (missing Release-\(schemeName))",
                    verified: false,
                    confidence: .potentialFlavor,
                    schemeName: schemeName,
                    buildConfigurations: configs,
                    explanation: msg
                )
                return (scheme, flavor)
            }
        }

        // Check if a custom scheme name matches a flavor suffix by alias/substring (e.g., scheme "ProductionApp" and config "Release-production")
        if let matchedEntry = flavorConfigMap.first(where: { key, _ in
            !claimedFlavorSuffixes.contains(key) && (lowerName.contains(key) || key.contains(lowerName) || FlavorEntrypointMapper.areAliases(lowerName, key))
        }) {
            claimedFlavorSuffixes.insert(matchedEntry.key)
            let configs = matchedEntry.value.configs.sorted()
            let explanation = "Scheme '\(schemeName)' matched to build configurations: \(configs.joined(separator: ", "))."
            let scheme = DiscoveredXcodeScheme(
                name: schemeName,
                confidence: .confirmedFlavor,
                buildConfigurations: configs,
                isSharedOnDisk: false,
                isListedByXcodebuild: isListedByXcode,
                explanation: explanation
            )
            let flavor = DetectedFlavor(
                name: schemeName,
                source: "Xcode scheme (\(configs.joined(separator: ", ")))",
                verified: true,
                confidence: .confirmedFlavor,
                schemeName: schemeName,
                buildConfigurations: configs,
                explanation: explanation
            )
            return (scheme, flavor)
        }

        if schemeName.caseInsensitiveCompare("Runner") == .orderedSame {
            let scheme = DiscoveredXcodeScheme(
                name: schemeName,
                confidence: .ordinaryScheme,
                buildConfigurations: allConfigs.filter { isStandardBaseConfiguration($0) },
                isSharedOnDisk: false,
                isListedByXcodebuild: isListedByXcode,
                explanation: "Default Runner Xcode scheme."
            )
            return (scheme, nil)
        }

        // Unverified custom scheme from xcodebuild: expose as a potential flavor with explanation
        let explanation: String
        if allConfigs.isEmpty {
            explanation = "Discovered via xcodebuild; scheme build configuration mapping could not be verified."
        } else {
            explanation = "Scheme '\(schemeName)' was discovered, but no matching 'Release-\(schemeName)' build configuration was found."
            warnings.append(explanation)
        }
        let scheme = DiscoveredXcodeScheme(
            name: schemeName,
            confidence: .potentialFlavor,
            buildConfigurations: [],
            isSharedOnDisk: false,
            isListedByXcodebuild: isListedByXcode,
            explanation: explanation
        )
        let flavor = DetectedFlavor(
            name: schemeName,
            source: "Xcode scheme (potential flavor)",
            verified: false,
            confidence: .potentialFlavor,
            schemeName: schemeName,
            buildConfigurations: [],
            explanation: explanation
        )
        return (scheme, flavor)
    }

    static func discoverSharedSchemesOnDisk(workspaceURL: URL?, projectURL: URL?) -> [String: ParsedXCScheme] {
        var result: [String: ParsedXCScheme] = [:]
        let fm = FileManager.default
        // Scheme files under a workspace can represent Pods and plugin projects.
        // The app project is authoritative; only use workspace schemes as a fallback
        // for layouts where the workspace itself is the app's only Xcode container.
        let containers = [projectURL ?? workspaceURL].compactMap { $0 }
        for container in containers {
            let schemesDir = container.appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for file in files where file.pathExtension == "xcscheme" {
                let parsed = XCSchemeParser.parse(url: file)
                result[parsed.name] = parsed
            }
        }
        return result
    }

    static func discoverLocalSchemesOnDisk(projectURL: URL?) -> [String] {
        guard let projectURL else { return [] }
        let localRoot = projectURL.appendingPathComponent("xcuserdata", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: localRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var schemes: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "xcscheme" else { continue }
            let parsed = XCSchemeParser.parse(url: url)
            let pathComponents = url.pathComponents
            let owner = pathComponents.first(where: { $0.hasSuffix(".xcuserdatad") })
                ?? pathComponents.first(where: { $0 != "xcuserdata" && $0.hasSuffix("xcschemes") })
                ?? "local user"
            schemes.append("\(parsed.name) · \(owner) · Local to this Mac")
        }
        return schemes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func decodeXcodeBuildJSON(from stdout: String) -> XcodeBuildListResponse? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let decoder = JSONDecoder()
        if let data = trimmed.data(using: .utf8),
           let decoded = try? decoder.decode(XcodeBuildListResponse.self, from: data),
           (decoded.project != nil || decoded.workspace != nil) {
            return decoded
        }
        // Handle any leading Xcode runtime warning lines before `{`
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            let jsonSlice = String(trimmed[firstBrace...lastBrace])
            if let data = jsonSlice.data(using: .utf8),
               let decoded = try? decoder.decode(XcodeBuildListResponse.self, from: data),
               (decoded.project != nil || decoded.workspace != nil) {
                return decoded
            }
        }
        return nil
    }
}

// MARK: - Android Flavor Detector

struct AndroidFlavorDetector: Sendable {
    func discover(project: URL) -> FlavorDiscoveryDiagnostics {
        var diagnostics = FlavorDiscoveryDiagnostics(platform: .androidAPK)
        let candidates = ["android/app/build.gradle.kts", "android/app/build.gradle"]
        guard let relative = candidates.first(where: { FileManager.default.fileExists(atPath: project.appendingPathComponent($0).path) }) else {
            let msg = "Android Gradle configuration (android/app/build.gradle or build.gradle.kts) was not found."
            diagnostics.errors.append(msg)
            diagnostics.emptyStateExplanation = msg
            return diagnostics
        }
        diagnostics.containerPath = relative
        let file = project.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            let msg = "Could not read \(relative)."
            diagnostics.errors.append(msg)
            diagnostics.emptyStateExplanation = msg
            return diagnostics
        }

        let clean = Self.withoutComments(text)
        guard let block = Self.namedBlock("productFlavors", in: clean) else {
            diagnostics.emptyStateExplanation = "No productFlavors block was found in \(relative). Use 'No Flavor' for standard builds."
            return diagnostics
        }
        let dimensionNames = Self.dimensionNames(in: clean)
        var dimensionValues: [(String, [String])] = []
        for child in Self.childBlocks(block) where child.name != "dimension" {
            let dimension = Self.value(after: "dimension", in: child.body) ?? ""
            dimensionValues.append((dimension, [child.name]))
        }
        guard !dimensionValues.isEmpty else {
            diagnostics.emptyStateExplanation = "productFlavors block in \(relative) contains no flavor definitions."
            return diagnostics
        }
        let inferredDimensions = dimensionValues.map(\.0).filter { !$0.isEmpty }
        let dimensions: [String]
        if !dimensionNames.isEmpty { dimensions = dimensionNames }
        else if !inferredDimensions.isEmpty { dimensions = Array(Set(inferredDimensions)).sorted() }
        else { dimensions = [""] }
        var grouped: [[String]] = []
        for dimension in dimensions {
            var names: [String] = []
            for pair in dimensionValues where pair.0 == dimension || (dimension.isEmpty && pair.0.isEmpty) {
                names.append(contentsOf: pair.1)
            }
            grouped.append(names)
        }
        guard grouped.allSatisfy({ !$0.isEmpty }) else {
            diagnostics.warnings.append("Some Android flavor dimensions in \(relative) had no matching flavors.")
            diagnostics.emptyStateExplanation = "Android flavor dimensions could not be combined."
            return diagnostics
        }
        let combinations = grouped.reduce([""]) { partial, values in
            partial.flatMap { prefix in values.map { prefix + $0 } }
        }
        let flavors = Array(Set(combinations)).sorted().map {
            DetectedFlavor(
                name: $0,
                source: "Android Gradle (static suggestion)",
                verified: false,
                confidence: .potentialFlavor,
                explanation: "Parsed from \(relative)."
            )
        }
        diagnostics.flavors = flavors
        return diagnostics
    }

    private static func withoutComments(_ input: String) -> String {
        input.replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\n]*"#, with: "", options: .regularExpression)
    }

    private static func dimensionNames(in input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)\bflavorDimensions\b[^\n]*"#) else { return [] }
        guard let strings = try? NSRegularExpression(pattern: #"['\"]([^'\"]+)['\"]"#) else { return [] }
        let ns = input as NSString
        var values: [String] = []
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let line = ns.substring(with: match.range)
            let lineNS = line as NSString
            for hit in strings.matches(in: line, range: NSRange(location: 0, length: lineNS.length)) {
                if let range = Range(hit.range(at: 1), in: line) { values.append(String(line[range])) }
            }
        }
        return values
    }

    private static func value(after key: String, in input: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\s*(?:=\\s*|\\(\\s*)?['\\\"]([^'\\\"]+)['\\\"]"),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }

    private static func namedBlock(_ name: String, in input: String) -> String? {
        guard let range = input.range(of: name), let open = input[range.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 1, cursor = input.index(after: open)
        while cursor < input.endIndex {
            if input[cursor] == "{" { depth += 1 }
            if input[cursor] == "}" { depth -= 1; if depth == 0 { return String(input[input.index(after: open)..<cursor]) } }
            cursor = input.index(after: cursor)
        }
        return nil
    }

    private static func childBlocks(_ input: String) -> [(name: String, body: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:create\s*\(\s*['\"]([^'\"]+)['\"]\s*\)|([A-Za-z_][A-Za-z0-9_]*))\s*\{"#) else { return [] }
        let ns = input as NSString
        return regex.matches(in: input, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let nameRange = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            let name = ns.substring(with: nameRange)
            let braceRange = ns.range(of: "{", range: NSRange(location: match.range.location, length: match.range.length))
            var level = 1, index = braceRange.location + 1
            while index < ns.length && level > 0 {
                let c = ns.substring(with: NSRange(location: index, length: 1))
                if c == "{" { level += 1 }
                if c == "}" { level -= 1 }
                index += 1
            }
            guard level == 0 else { return nil }
            return (name, ns.substring(with: NSRange(location: braceRange.location + 1, length: index - braceRange.location - 2)))
        }
    }
}

// MARK: - Unified Flavor Discovery Service

struct FlavorDiscoveryService: Sendable {
    var xcodebuildExecutable: URL

    init(xcodebuildExecutable: URL = URL(fileURLWithPath: "/usr/bin/xcodebuild")) {
        self.xcodebuildExecutable = xcodebuildExecutable
    }

    func android(project: URL) -> [DetectedFlavor] {
        AndroidFlavorDetector().discover(project: project).flavors
    }

    func discoverAndroid(project: URL) -> FlavorDiscoveryDiagnostics {
        AndroidFlavorDetector().discover(project: project)
    }

    func discoverIOS(project: URL, executor: any CLIExecuting) async -> FlavorDiscoveryDiagnostics {
        await IOSFlavorDetector(xcodebuildExecutable: xcodebuildExecutable).discover(project: project, executor: executor)
    }

    func ios(project: URL, executor: any CLIExecuting) async throws -> [DetectedFlavor] {
        let diagnostics = await discoverIOS(project: project, executor: executor)
        if !diagnostics.errors.isEmpty && diagnostics.flavors.isEmpty {
            throw BuildValidationError(diagnostics.errors.joined(separator: " "))
        }
        return diagnostics.flavors
    }
}

// MARK: - Flavor-to-Entrypoint Mapping

struct FlavorEntrypointMapper: Sendable {
    private static let aliasGroups: [[String]] = [
        ["dev", "development", "develop", "devel", "local"],
        ["prod", "production", "live", "release"],
        ["stg", "stage", "staging", "preprod", "preproduction"],
        ["uat", "acceptance", "useracceptance", "preview", "beta"],
        ["qa", "test", "testing", "quality"],
        ["demo", "sandbox"]
    ]

    static func areAliases(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizeToken(lhs)
        let b = normalizeToken(rhs)
        if a == b && !a.isEmpty { return true }
        return aliasGroups.contains { group in group.contains(a) && group.contains(b) }
    }

    /// Resolves the best entrypoint using the 5 priority tiers:
    /// 1. Existing user-defined manual mapping.
    /// 2. Previously saved selection.
    /// 3. Exact normalized filename match.
    /// 4. Reasonable naming aliases.
    /// 5. `lib/main.dart` fallback (or first discovered entrypoint).
    static func resolveEntrypoint(
        for flavor: String?,
        entrypoints: [String],
        manualMapping: String? = nil,
        savedSelection: String? = nil
    ) -> String? {
        // 1. Existing user-defined manual mapping
        if let manualMapping, !manualMapping.isEmpty {
            if entrypoints.contains(manualMapping) || entrypoints.isEmpty {
                return manualMapping
            }
        }

        // 2. Previously saved selection
        if let savedSelection, !savedSelection.isEmpty, entrypoints.contains(savedSelection) {
            return savedSelection
        }

        guard !entrypoints.isEmpty else { return manualMapping ?? savedSelection }

        // If flavor is present, try Tier 3 (exact normalized filename match) and Tier 4 (naming aliases)
        if let flavor, !flavor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let suggested = suggestEntrypoint(for: flavor, in: entrypoints) {
                return suggested
            }
        }

        // 5. lib/main.dart fallback
        if entrypoints.contains("lib/main.dart") {
            return "lib/main.dart"
        }
        return entrypoints.first
    }

    static func suggestEntrypoint(for flavor: String, in entrypoints: [String]) -> String? {
        let trimmedFlavor = flavor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFlavor.isEmpty, !entrypoints.isEmpty else { return nil }

        let normalizedFlavor = normalizeToken(trimmedFlavor)
        guard !normalizedFlavor.isEmpty else { return nil }

        // Prepare candidate metadata sorted by path depth (shallower first), then standard order
        let candidates: [(path: String, token: String, depth: Int)] = entrypoints.compactMap { path in
            guard path != "lib/main.dart" else { return nil }
            let token = extractFlavorToken(fromEntrypointPath: path)
            guard !token.isEmpty else { return nil }
            let depth = path.filter { $0 == "/" }.count
            return (path, token, depth)
        }.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        // Tier 3: Exact normalized filename match (e.g., dev -> lib/main_dev.dart, uat -> lib/bootstrap/main_uat.dart)
        if let exact = candidates.first(where: { $0.token == normalizedFlavor }) {
            return exact.path
        }

        // Tier 4a: Direct alias match (e.g., prod <-> production, dev <-> development, stg <-> staging)
        if let aliasMatch = candidates.first(where: { areAliases($0.token, normalizedFlavor) }) {
            return aliasMatch.path
        }

        // Tier 4b: Multi-dimension / camelCase / hyphenated flavor tokens (e.g., "uatBlue" -> "uat", "ios-staging" -> "staging")
        let subTokens = splitTokens(trimmedFlavor)
        for sub in subTokens where !sub.isEmpty {
            if let exactTokenMatch = candidates.first(where: { $0.token == sub }) {
                return exactTokenMatch.path
            }
            if let aliasTokenMatch = candidates.first(where: { areAliases($0.token, sub) }) {
                return aliasTokenMatch.path
            }
        }

        return nil
    }

    private static func extractFlavorToken(fromEntrypointPath path: String) -> String {
        let filename = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let lower = filename.lowercased()
        let stripped: String
        if lower.hasPrefix("main_") || lower.hasPrefix("main-") || lower.hasPrefix("main.") {
            stripped = String(lower.dropFirst(5))
        } else if lower.hasSuffix("_main") || lower.hasSuffix("-main") || lower.hasSuffix(".main") {
            stripped = String(lower.dropLast(5))
        } else if lower.hasPrefix("main") && lower.count > 4 {
            stripped = String(lower.dropFirst(4))
        } else {
            stripped = lower
        }
        return normalizeToken(stripped)
    }

    private static func normalizeToken(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func splitTokens(_ value: String) -> [String] {
        // Split camelCase and non-alphanumeric separators
        let withSpaces = value.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        return withSpaces
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { normalizeToken($0) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Discovery Cache

final class BuildDiscoveryCache: @unchecked Sendable {
    struct CachedEntrypoints: Sendable {
        var fingerprint: String
        var result: DartEntrypointDiscoveryResult
    }

    struct CachedFlavors: Sendable {
        var fingerprint: String
        var diagnostics: FlavorDiscoveryDiagnostics
    }

    private let lock = NSLock()
    private var entrypointCache: [String: CachedEntrypoints] = [:]
    private var flavorCache: [String: CachedFlavors] = [:]
    private var inFlightFlavorTasks: [String: (id: UUID, task: Task<FlavorDiscoveryDiagnostics, Never>)] = [:]

    func cachedEntrypoints(for project: URL) -> DartEntrypointDiscoveryResult? {
        let key = Self.canonicalPath(project)
        let fp = Self.entrypointFingerprint(for: project)
        lock.lock()
        defer { lock.unlock() }
        guard let cached = entrypointCache[key], cached.fingerprint == fp else { return nil }
        return cached.result
    }

    func storeEntrypoints(_ result: DartEntrypointDiscoveryResult, for project: URL) {
        // Do not cache failed or empty discovery results indefinitely
        guard result.errors.isEmpty, !result.entrypoints.isEmpty else { return }
        let key = Self.canonicalPath(project)
        let fp = Self.entrypointFingerprint(for: project)
        lock.lock()
        defer { lock.unlock() }
        entrypointCache[key] = CachedEntrypoints(fingerprint: fp, result: result)
    }

    func cachedFlavors(for project: URL, platform: ReleasePlatform) -> FlavorDiscoveryDiagnostics? {
        let key = "\(Self.canonicalPath(project))::\(platform.familyKey)"
        let fp = Self.flavorFingerprint(for: project, platform: platform)
        lock.lock()
        defer { lock.unlock() }
        guard let cached = flavorCache[key], cached.fingerprint == fp else { return nil }
        return cached.diagnostics
    }

    func storeFlavors(_ diagnostics: FlavorDiscoveryDiagnostics, for project: URL, platform: ReleasePlatform) {
        // Do not cache failed discovery results
        guard diagnostics.errors.isEmpty else { return }
        // Only cache when we either have flavors or a confirmed default-scheme explanation
        guard !diagnostics.flavors.isEmpty || !diagnostics.discoveredSchemes.isEmpty else { return }
        let key = "\(Self.canonicalPath(project))::\(platform.familyKey)"
        let fp = Self.flavorFingerprint(for: project, platform: platform)
        lock.lock()
        defer { lock.unlock() }
        flavorCache[key] = CachedFlavors(fingerprint: fp, diagnostics: diagnostics)
    }

    func discoverFlavors(
        for project: URL,
        platform: ReleasePlatform,
        force: Bool,
        operation: @escaping @Sendable () async -> FlavorDiscoveryDiagnostics
    ) async -> FlavorDiscoveryDiagnostics {
        if !force, let cached = cachedFlavors(for: project, platform: platform) { return cached }
        let key = "\(Self.canonicalPath(project))::\(platform.familyKey)"
        let startingFingerprint = Self.flavorFingerprint(for: project, platform: platform)
        let (taskID, task) = taskForFlavorDiscovery(key: key, operation: operation)
        let diagnostics = await task.value
        clearFlavorDiscoveryTask(key: key, id: taskID)
        if Self.flavorFingerprint(for: project, platform: platform) == startingFingerprint {
            storeFlavors(diagnostics, for: project, platform: platform)
        }
        return diagnostics
    }

    private func taskForFlavorDiscovery(
        key: String,
        operation: @escaping @Sendable () async -> FlavorDiscoveryDiagnostics
    ) -> (UUID, Task<FlavorDiscoveryDiagnostics, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlightFlavorTasks[key] {
            return (existing.id, existing.task)
        }
        let id = UUID()
        let task = Task { await operation() }
        inFlightFlavorTasks[key] = (id, task)
        return (id, task)
    }

    private func clearFlavorDiscoveryTask(key: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if inFlightFlavorTasks[key]?.id == id { inFlightFlavorTasks[key] = nil }
    }

    func invalidate(project: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let project {
            let prefix = Self.canonicalPath(project)
            entrypointCache.removeValue(forKey: prefix)
            flavorCache = flavorCache.filter { !$0.key.hasPrefix(prefix + "::") }
            inFlightFlavorTasks = inFlightFlavorTasks.filter { !$0.key.hasPrefix(prefix + "::") }
        } else {
            entrypointCache.removeAll()
            flavorCache.removeAll()
            inFlightFlavorTasks.removeAll()
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func entrypointFingerprint(for project: URL) -> String {
        let fm = FileManager.default
        let lib = project.appendingPathComponent("lib", isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: lib,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "missing-lib"
        }
        var records: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "dart" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            records.append("\(url.path):\(mtime):\(size)")
        }
        records.sort()
        return records.joined(separator: "|")
    }

    static func flavorFingerprint(for project: URL, platform: ReleasePlatform) -> String {
        let fm = FileManager.default
        var records: [String] = []

        func recordFile(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else {
                records.append("\(url.path):missing")
                return
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            records.append("\(url.path):\(mtime):\(size)")
        }

        if platform.isAndroid {
            recordFile(project.appendingPathComponent("android/app/build.gradle.kts"))
            recordFile(project.appendingPathComponent("android/app/build.gradle"))
        } else if platform == .iOSIPA {
            let selection = IOSFlavorDetector.locateXcodeContainer(in: project)
            if let workspace = selection.workspaceURL {
                recordFile(workspace.appendingPathComponent("contents.xcworkspacedata"))
            }
            if let appProject = selection.projectURL {
                recordFile(appProject.appendingPathComponent("project.pbxproj"))
                let schemesDir = appProject.appendingPathComponent("xcshareddata/xcschemes")
                let schemes = (try? fm.contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for scheme in schemes.sorted(by: { $0.path < $1.path }) where scheme.pathExtension == "xcscheme" {
                    recordFile(scheme)
                }
                let localRoot = appProject.appendingPathComponent("xcuserdata", isDirectory: true)
                if let enumerator = fm.enumerator(at: localRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let scheme as URL in enumerator where scheme.pathExtension == "xcscheme" {
                        recordFile(scheme)
                    }
                }
            }
        }
        return records.joined(separator: "|")
    }
}

// MARK: - Build Release ViewModel

@MainActor @Observable final class BuildReleaseViewModel {
    private static let noFlavorSentinel = "__NO_FLAVOR__"

    let project: FlutterProject
    let executor: any CLIExecuting
    let store: BuildReleaseStore
    let cache: BuildDiscoveryCache
    private let defaults: UserDefaults
    var flavorDiscoveryService: FlavorDiscoveryService
    var entrypointDetector: DartEntrypointDetector

    var configuration: BuildConfiguration {
        didSet {
            store.saveConfiguration(configuration)
        }
    }

    private(set) var detectedEntrypoints: [DetectedEntrypoint] = []
    var entrypoints: [String] { detectedEntrypoints.map(\.path) }
    private(set) var flavors: [DetectedFlavor] = []
    private(set) var diagnostics: FlavorDiscoveryDiagnostics
    private(set) var entrypointDiagnostics = DartEntrypointDiscoveryResult()
    private(set) var discoveryError: String?
    private(set) var flavorValidationMessage: String?
    private(set) var entrypointValidationMessage: String?
    private(set) var isDiscovering = false
    var isManualFlavorOverride = false
    var isManualEntrypointOverride = false

    private var discoveryGeneration: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?

    init(
        project: FlutterProject,
        sdkVersion: String,
        executor: any CLIExecuting,
        store: BuildReleaseStore,
        defaults: UserDefaults = .standard,
        cache: BuildDiscoveryCache = BuildDiscoveryCache(),
        flavorDiscoveryService: FlavorDiscoveryService = FlavorDiscoveryService(),
        entrypointDetector: DartEntrypointDetector = DartEntrypointDetector()
    ) {
        self.project = project
        self.executor = executor
        self.store = store
        self.defaults = defaults
        self.cache = cache
        self.flavorDiscoveryService = flavorDiscoveryService
        self.entrypointDetector = entrypointDetector
        let initialConfig = store.configuration(projectID: project.id, sdkVersion: sdkVersion)
        self.configuration = initialConfig
        if let cached = cache.cachedFlavors(for: URL(fileURLWithPath: project.path), platform: initialConfig.platform) {
            self.diagnostics = cached
            self.flavors = cached.flavors
            self.discoveryError = cached.errors.first
        } else {
            self.diagnostics = FlavorDiscoveryDiagnostics(platform: initialConfig.platform)
        }
    }

    func selectPlatform(_ platform: ReleasePlatform) async {
        let previousPlatform = configuration.platform
        if previousPlatform != platform {
            var updated = configuration
            updated.platform = platform
            if !platform.isAndroid {
                updated.splitPerABI = false
            }
            configuration = updated
        }
        await refreshDiscovery(force: false)
    }

    func selectFlavor(_ flavor: String?, isManual: Bool = false) {
        let normalizedFlavor = (flavor?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        isManualFlavorOverride = isManual && normalizedFlavor != nil && !flavors.contains(where: { $0.name == normalizedFlavor })
        configuration.flavor = normalizedFlavor
        persistFlavorSelection(normalizedFlavor, for: configuration.platform)
        updateFlavorValidationMessage()
        applyEntrypointForCurrentFlavor(keepValidCurrentIfUnmapped: false)
    }

    func selectEntrypoint(_ entrypoint: String, isManual: Bool = true) {
        let trimmed = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        configuration.entrypoint = trimmed
        isManualEntrypointOverride = isManual && !entrypoints.contains(trimmed)
        if isManual {
            defaults.set(trimmed, forKey: manualEntrypointKey(platform: configuration.platform, flavor: configuration.flavor))
        }
        defaults.set(trimmed, forKey: savedEntrypointKey(platform: configuration.platform, flavor: configuration.flavor))
        updateEntrypointValidationMessage()
    }

    func clearManualEntrypointOverride() {
        defaults.removeObject(forKey: manualEntrypointKey(platform: configuration.platform, flavor: configuration.flavor))
        isManualEntrypointOverride = false
        applyEntrypointForCurrentFlavor(keepValidCurrentIfUnmapped: false)
    }

    func refresh(force: Bool = true) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            await self?.refreshDiscovery(force: force)
        }
    }

    func refreshDiscovery(force: Bool = false) async {
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        let targetPlatform = configuration.platform
        let projectURL = URL(fileURLWithPath: project.path)

        isDiscovering = true
        discoveryError = nil
        flavorValidationMessage = nil

        let detector = entrypointDetector
        let flavorService = flavorDiscoveryService
        let currentCache = cache
        let currentExecutor = executor

        // 1. Discover Dart entrypoints (preserving existing list until new results arrive)
        let entrypointResult: DartEntrypointDiscoveryResult
        if !force, let cached = currentCache.cachedEntrypoints(for: projectURL) {
            entrypointResult = cached
        } else {
            let discovered = await Task.detached {
                detector.discoverWithDiagnostics(project: projectURL)
            }.value
            currentCache.storeEntrypoints(discovered, for: projectURL)
            entrypointResult = discovered
        }

        guard !Task.isCancelled, generation == discoveryGeneration, targetPlatform == configuration.platform else {
            return
        }

        // Do not accidentally clear entrypoints if a transient reload happens; update with discovered entrypoints
        self.entrypointDiagnostics = entrypointResult
        self.detectedEntrypoints = entrypointResult.entrypoints

        // 2. Discover Platform Flavors
        let platformDiagnostics: FlavorDiscoveryDiagnostics
        if targetPlatform.isAndroid || targetPlatform == .iOSIPA {
            platformDiagnostics = await currentCache.discoverFlavors(for: projectURL, platform: targetPlatform, force: force) {
                if targetPlatform.isAndroid {
                    return flavorService.discoverAndroid(project: projectURL)
                }
                return await flavorService.discoverIOS(project: projectURL, executor: currentExecutor)
            }
        } else {
            var macosDiag = FlavorDiscoveryDiagnostics(platform: targetPlatform)
            macosDiag.emptyStateExplanation = "Flavor or scheme discovery is not required for macOS targets."
            platformDiagnostics = macosDiag
        }

        guard !Task.isCancelled, generation == discoveryGeneration, targetPlatform == configuration.platform else {
            return
        }

        self.diagnostics = platformDiagnostics
        self.flavors = platformDiagnostics.flavors
        self.discoveryError = platformDiagnostics.errors.first
        self.isDiscovering = false

        // 3. Resolve platform-specific flavor selection
        resolveFlavorSelectionAfterDiscovery(for: targetPlatform)

        // 4. Resolve entrypoint selection (preserving valid selections and platform mappings)
        applyEntrypointForCurrentFlavor(keepValidCurrentIfUnmapped: true)
        updateFlavorValidationMessage()
        updateEntrypointValidationMessage()
    }

    private func resolveFlavorSelectionAfterDiscovery(for platform: ReleasePlatform) {
        if platform == .macOSApp {
            if !isManualFlavorOverride {
                configuration.flavor = nil
            }
            return
        }

        let storedValue = defaults.string(forKey: flavorKey(platform))
        if let storedValue {
            if storedValue == Self.noFlavorSentinel {
                configuration.flavor = nil
                return
            }
            configuration.flavor = storedValue
            if !flavors.contains(where: { $0.name == storedValue }) && !isManualFlavorOverride {
                flavorValidationMessage = "Saved flavor or scheme ‘\(storedValue)’ is not in the detected list for \(platform.title). Select a detected option, keep as manual override, or choose No Flavor."
            }
            return
        }

        // No stored flavor for this platform yet
        if let current = configuration.flavor {
            if flavors.contains(where: { $0.name == current }) || isManualFlavorOverride {
                persistFlavorSelection(current, for: platform)
                return
            }
        }

        // Default selection for this platform:
        // If confirmed or potential flavors exist, select the first confirmed flavor (or nil if none)
        if let firstConfirmed = flavors.first(where: { $0.confidence == .confirmedFlavor }) {
            configuration.flavor = firstConfirmed.name
            persistFlavorSelection(firstConfirmed.name, for: platform)
        } else if let firstFlavor = flavors.first {
            configuration.flavor = firstFlavor.name
            persistFlavorSelection(firstFlavor.name, for: platform)
        } else {
            configuration.flavor = nil
        }
    }

    private func applyEntrypointForCurrentFlavor(keepValidCurrentIfUnmapped: Bool) {
        let currentFlavor = configuration.flavor
        let manual = defaults.string(forKey: manualEntrypointKey(platform: configuration.platform, flavor: currentFlavor))
            ?? (currentFlavor != nil ? defaults.string(forKey: projectFlavorManualEntrypointKey(flavor: currentFlavor!)) : nil)
        let saved = defaults.string(forKey: savedEntrypointKey(platform: configuration.platform, flavor: currentFlavor))

        // If user has an explicit manual mapping for this platform/flavor, always honor it
        if let manual, !manual.isEmpty {
            if entrypoints.contains(manual) || entrypointExistsOnDisk(manual) {
                configuration.entrypoint = manual
                updateEntrypointValidationMessage()
                return
            }
        }

        // If switching platforms and no flavor-specific mapping is triggered, keep current entrypoint if still valid
        if keepValidCurrentIfUnmapped,
           currentFlavor == nil,
           saved == nil,
           entrypoints.contains(configuration.entrypoint) {
            updateEntrypointValidationMessage()
            return
        }

        if let resolved = FlavorEntrypointMapper.resolveEntrypoint(
            for: currentFlavor,
            entrypoints: entrypoints,
            manualMapping: manual,
            savedSelection: saved
        ) {
            configuration.entrypoint = resolved
            defaults.set(resolved, forKey: savedEntrypointKey(platform: configuration.platform, flavor: currentFlavor))
        }
        updateEntrypointValidationMessage()
    }

    func updateFlavorValidationMessage() {
        guard let selected = configuration.flavor, !selected.isEmpty else {
            flavorValidationMessage = nil
            return
        }
        if let matched = flavors.first(where: { $0.name == selected }) {
            if matched.confidence == .potentialFlavor, let explanation = matched.explanation {
                flavorValidationMessage = explanation
            } else {
                flavorValidationMessage = nil
            }
        } else if isManualFlavorOverride {
            flavorValidationMessage = "Using manual flavor override ‘\(selected)’."
        } else if discoveryError == nil {
            flavorValidationMessage = "Selected flavor or scheme ‘\(selected)’ was not automatically verified. It will be passed as --flavor \(selected)."
        }
    }

    func updateEntrypointValidationMessage() {
        let current = configuration.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            entrypointValidationMessage = "Select or enter a Dart entrypoint inside lib/."
            return
        }
        guard current.hasPrefix("lib/"), !current.contains(".."), current.hasSuffix(".dart") else {
            entrypointValidationMessage = "The Dart entrypoint must be a relative path under lib/ ending in .dart."
            return
        }
        if let detected = detectedEntrypoints.first(where: { $0.path == current }) {
            if detected.confidence == .potential {
                entrypointValidationMessage = detected.explanation ?? "Marked as a potential entrypoint."
            } else {
                entrypointValidationMessage = nil
            }
            return
        }
        if entrypointExistsOnDisk(current) {
            entrypointValidationMessage = "Using manual entrypoint ‘\(current)’ (top-level main() was not detected)."
        } else {
            entrypointValidationMessage = "Selected entrypoint ‘\(current)’ was not found in this project."
        }
    }

    var isEntrypointValidForBuild: Bool {
        let current = configuration.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.hasPrefix("lib/"), !current.contains(".."), current.hasSuffix(".dart") else { return false }
        return entrypoints.contains(current) || entrypointExistsOnDisk(current)
    }

    var isFlavorValidForBuild: Bool {
        guard let flavor = configuration.flavor, !flavor.isEmpty else { return true }
        return !flavor.hasPrefix("-") && flavor.rangeOfCharacter(from: .newlines) == nil
    }

    private func entrypointExistsOnDisk(_ relativePath: String) -> Bool {
        let root = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private func persistFlavorSelection(_ flavor: String?, for platform: ReleasePlatform) {
        let value = flavor ?? Self.noFlavorSentinel
        defaults.set(value, forKey: flavorKey(platform))
    }

    private func flavorKey(_ platform: ReleasePlatform) -> String {
        "buildRelease.flavor.\(project.id).\(platform.familyKey)"
    }

    private func savedEntrypointKey(platform: ReleasePlatform, flavor: String?) -> String {
        "buildRelease.entrypoint.\(project.id).\(platform.rawValue).\(flavor ?? "none")"
    }

    private func manualEntrypointKey(platform: ReleasePlatform, flavor: String?) -> String {
        "buildRelease.manualEntrypoint.\(project.id).\(platform.familyKey).\(flavor ?? "none")"
    }

    private func projectFlavorManualEntrypointKey(flavor: String) -> String {
        "buildRelease.manualEntrypoint.\(project.id).any.\(flavor)"
    }
}

// MARK: - Build Release Store

@MainActor @Observable final class BuildReleaseStore {
    private let defaults: UserDefaults
    let releaseStorage: ReleaseStorageService
    private let historyKey = "buildRelease.history.v1"
    private let presetsKey = "buildRelease.presets.v1"
    private let configurationsKey = "buildRelease.configurations.v1"
    let discoveryCache = BuildDiscoveryCache()
    private(set) var history: [BuildHistoryRecord] = []
    private(set) var presets: [String: [BuildPreset]] = [:]
    var selectedRecord: UUID?
    var activeTask: Task<Void, Never>?
    var activeID: UUID?
    var isCancelling = false
    var startedAt: Date?
    var stage: BuildStage = .preparing
    var currentTask = ""
    var liveLog = ""
    var error: String?
    var artifact: URL?
    private var pendingLog = ""
    private var logFlushTask: Task<Void, Never>?
    private var activeLogHandle: FileHandle?

    init(defaults: UserDefaults = .standard, releaseStorage: ReleaseStorageService? = nil) {
        self.defaults = defaults
        self.releaseStorage = releaseStorage ?? ReleaseStorageService(defaultsBox: ReleaseStorageDefaults(defaults))
        history = (try? defaults.data(forKey: historyKey).map { try JSONDecoder().decode([BuildHistoryRecord].self, from: $0) }) ?? []
        presets = (try? defaults.data(forKey: presetsKey).map { try JSONDecoder().decode([String: [BuildPreset]].self, from: $0) }) ?? [:]
    }

    func makeViewModel(project: FlutterProject, sdkVersion: String, executor: any CLIExecuting) -> BuildReleaseViewModel {
        BuildReleaseViewModel(
            project: project,
            sdkVersion: sdkVersion,
            executor: executor,
            store: self,
            defaults: defaults,
            cache: discoveryCache
        )
    }

    func savePreset(_ config: BuildConfiguration, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var values = presets[config.projectID, default: []]
        values.removeAll { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        values.append(BuildPreset(name: name, configuration: config))
        presets[config.projectID] = values
        persistPresets()
    }
    func removePreset(_ preset: BuildPreset) { presets[preset.configuration.projectID]?.removeAll { $0.id == preset.id }; persistPresets() }
    func removeHistory(_ id: UUID) { history.removeAll { $0.id == id }; persistHistory() }
    func deleteArchivedRelease(_ record: BuildHistoryRecord) async throws {
        guard let path = record.releaseDirectory else { throw ReleaseStorageError.metadataUnavailable }
        try await releaseStorage.removeRelease(at: URL(fileURLWithPath: path, isDirectory: true))
        if let index = history.firstIndex(where: { $0.id == record.id }) {
            history[index].archiveStatus = .missing
            history[index].archivedArtifacts = []
            history[index].archivedSymbolFiles = []
            history[index].archivedSizeBytes = 0
            persistHistory()
        }
    }
    func rewriteReleaseRootPaths(from source: URL, to destination: URL) {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        for index in history.indices {
            guard let releasePath = history[index].releaseDirectory,
                  releasePath == sourcePath || releasePath.hasPrefix(sourcePath + "/") else { continue }
            history[index].releaseDirectory = destinationPath + String(releasePath.dropFirst(sourcePath.count))
        }
        persistHistory()
    }
    func cancel() { guard activeTask != nil else { return }; isCancelling = true; activeTask?.cancel() }

    func configuration(projectID: String, sdkVersion: String) -> BuildConfiguration {
        let values = (try? defaults.data(forKey: configurationsKey).map { try JSONDecoder().decode([String: BuildConfiguration].self, from: $0) }) ?? [:]
        let archiveByDefault = defaults.object(forKey: "buildRelease.archiveByDefault") as? Bool ?? true
        var configuration = values[projectID] ?? BuildConfiguration(projectID: projectID, sdkVersion: sdkVersion, archiveRelease: archiveByDefault)
        configuration.sdkVersion = sdkVersion
        return configuration
    }

    func saveConfiguration(_ configuration: BuildConfiguration) {
        var values = (try? defaults.data(forKey: configurationsKey).map { try JSONDecoder().decode([String: BuildConfiguration].self, from: $0) }) ?? [:]
        var saved = configuration
        saved.defines = saved.defines.map { BuildDefine(id: $0.id, key: $0.key, value: "") }
        values[configuration.projectID] = saved
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: configurationsKey) }
    }

    func start(config: BuildConfiguration, project: URL, projectName: String? = nil, sdkLabel: String, service: FlutterBuildService, buildID requestedBuildID: UUID? = nil) {
        guard activeTask == nil else { error = "A build is already running."; return }
        let id = requestedBuildID ?? UUID()
        let logFile = Self.makeLogFile(id: id)
        var record = BuildHistoryRecord(id: id, configuration: config, sdkLabel: sdkLabel, startedAt: Date(), endedAt: nil, status: .running, stage: .preparing, exitCode: nil, artifactPath: nil, exportedArtifactPath: nil, exportError: nil, log: "", logFilePath: logFile?.url.path, error: nil)
        record.projectIdentity = ReleaseStorageService.stableProjectID(at: project, projectName: projectName ?? project.lastPathComponent)
        activeLogHandle = logFile?.handle
        activeID = record.id; startedAt = record.startedAt; isCancelling = false; pendingLog = ""; stage = .preparing; liveLog = ""; error = nil; artifact = nil
        history.insert(record, at: 0); persistHistory()
        activeTask = Task { [weak self] in
            guard let self else { return }
            var release: ReleaseStorageLocation?
            var effectiveConfig = config
            var flutterBuildStatus: BuildJobStatus = .running
            do {
                if effectiveConfig.obfuscate { effectiveConfig.generateDebugSymbols = true }
                if let splitDirectory = effectiveConfig.splitDebugInfo, !splitDirectory.isEmpty { effectiveConfig.generateDebugSymbols = true }
                let shouldPrepareStorage = effectiveConfig.archiveRelease || effectiveConfig.generateDebugSymbols || effectiveConfig.obfuscate || effectiveConfig.splitDebugInfo != nil
                if shouldPrepareStorage {
                    release = try await releaseStorage.prepareReleaseDirectory(for: effectiveConfig, project: project, projectName: projectName ?? project.lastPathComponent, buildID: id)
                    if effectiveConfig.generateDebugSymbols || effectiveConfig.obfuscate {
                        effectiveConfig.splitDebugInfo = release?.symbolsURL.path
                    }
                    if let index = history.firstIndex(where: { $0.id == record.id }) {
                        history[index].configuration = effectiveConfig
                        history[index].releaseDirectory = release?.rootURL.path
                        history[index].archiveStatus = effectiveConfig.archiveRelease ? .pending : .notRequested
                        persistHistory()
                    }
                }
                self.stage = .validating; self.update(record.id, stage: .validating)
                self.stage = .resolvingDependencies; self.update(record.id, stage: .resolvingDependencies)
                let buildConfiguration = effectiveConfig
                let result = try await releaseStorage.withStorageAccess {
                    try await service.validate(buildConfiguration, project: project)
                    return try await service.run(buildConfiguration, project: project) { [weak self] event in
                        await MainActor.run { self?.append(event.text, id: record.id); self?.parseStage(event.text) }
                    }
                }
                guard result.exitCode == 0 else { throw BuildValidationError("Flutter exited with code \(result.exitCode). Review the build log.") }
                flutterBuildStatus = .succeeded
                if let index = history.firstIndex(where: { $0.id == record.id }) { history[index].buildStatus = .succeeded; persistHistory() }
                self.flushLog(id: record.id)
                try? self.activeLogHandle?.close(); self.activeLogHandle = nil
                let found = try await releaseStorage.locateArtifacts(project: project, configuration: effectiveConfig, since: record.startedAt)
                guard !found.isEmpty else { throw BuildValidationError("Flutter exited successfully, but no .\(effectiveConfig.platform.fileExtension) artifact could be verified.") }
                self.stage = .archiving; self.update(record.id, stage: .archiving, exitCode: result.exitCode)
                var archived: [ArchivedArtifact] = []
                var symbolFiles: [String] = []
                if let release {
                    if effectiveConfig.archiveRelease {
                        archived = try await releaseStorage.archiveArtifacts(found, to: release)
                    }
                    symbolFiles = try await releaseStorage.discoverSymbols(in: release)
                    if effectiveConfig.obfuscate && symbolFiles.isEmpty {
                        throw BuildValidationError("The build completed, but Flutter did not produce Dart symbol files for the obfuscated release.")
                    }
                    _ = try await releaseStorage.archiveBuildLog(from: logFile?.url, text: self.liveLog, to: release)
                    let metadata = try await Self.makeMetadata(
                        buildID: id,
                        projectName: projectName ?? project.lastPathComponent,
                        project: project,
                        configuration: effectiveConfig,
                        sdkLabel: sdkLabel,
                        service: service,
                        releaseStorage: releaseStorage,
                        result: .succeeded,
                        archiveResult: effectiveConfig.archiveRelease ? .archived : .partial,
                        duration: Date().timeIntervalSince(record.startedAt),
                        createdAt: record.startedAt,
                        artifacts: archived,
                        symbols: symbolFiles
                    )
                    try await releaseStorage.saveBuildMetadata(metadata, to: release)
                }
                self.artifact = found.first
                var exportedPath: String?
                if let output = effectiveConfig.outputDestination, !output.isEmpty {
                    do { exportedPath = try Self.copyArtifact(found[0], to: URL(fileURLWithPath: output, isDirectory: true)).path }
                    catch { self.setExportError(record.id, error.localizedDescription) }
                }
                self.finish(record.id, status: .succeeded, stage: .completed, artifact: found[0].path, exportedArtifact: exportedPath, exitCode: result.exitCode)
                if let index = self.history.firstIndex(where: { $0.id == record.id }) {
                    self.history[index].archiveStatus = release.map { _ in effectiveConfig.archiveRelease ? .archived : .partial } ?? .notRequested
                    self.history[index].archivedArtifacts = archived.map(\.relativePath)
                    self.history[index].archivedSymbolFiles = symbolFiles
                    self.history[index].archivedSizeBytes = archived.reduce(Int64(0)) { $0 + $1.sizeBytes }
                    self.persistHistory()
                }
            } catch is CancellationError {
                self.flushLog(id: record.id); try? self.activeLogHandle?.close(); self.activeLogHandle = nil
                flutterBuildStatus = .cancelled
                if let index = history.firstIndex(where: { $0.id == record.id }) { history[index].buildStatus = .cancelled; persistHistory() }
                if let release { await self.preserveFailedRelease(release, buildID: id, project: project, projectName: projectName ?? project.lastPathComponent, configuration: effectiveConfig, sdkLabel: sdkLabel, service: service, record: record, status: .cancelled) }
                self.stage = .cancelled; self.finish(record.id, status: .cancelled, stage: .cancelled, error: "Build cancelled.")
            } catch {
                self.flushLog(id: record.id); try? self.activeLogHandle?.close(); self.activeLogHandle = nil
                if flutterBuildStatus == .running { flutterBuildStatus = .failed }
                if let index = history.firstIndex(where: { $0.id == record.id }) { history[index].buildStatus = flutterBuildStatus; persistHistory() }
                if let release { await self.preserveFailedRelease(release, buildID: id, project: project, projectName: projectName ?? project.lastPathComponent, configuration: effectiveConfig, sdkLabel: sdkLabel, service: service, record: record, status: flutterBuildStatus) }
                if let index = history.firstIndex(where: { $0.id == record.id }), release != nil { history[index].archiveStatus = .failed; persistHistory() }
                self.error = error.localizedDescription; self.stage = .failed
                self.finish(record.id, status: .failed, stage: .failed, error: error.localizedDescription)
            }
            self.flushLog(id: record.id); try? self.activeLogHandle?.close(); self.activeLogHandle = nil
            self.activeTask = nil; self.activeID = nil; self.isCancelling = false
        }
    }

    private func preserveFailedRelease(_ release: ReleaseStorageLocation, buildID: UUID, project: URL, projectName: String, configuration: BuildConfiguration, sdkLabel: String, service: FlutterBuildService, record: BuildHistoryRecord, status: BuildJobStatus) async {
        do {
            let symbols = try await releaseStorage.discoverSymbols(in: release)
            let logURL = record.logFilePath.map { URL(fileURLWithPath: $0) }
            _ = try await releaseStorage.archiveBuildLog(from: logURL, text: liveLog, to: release)
            let metadata = try await Self.makeMetadata(buildID: buildID, projectName: projectName, project: project, configuration: configuration, sdkLabel: sdkLabel, service: service, releaseStorage: releaseStorage, result: status, archiveResult: .partial, duration: Date().timeIntervalSince(record.startedAt), createdAt: record.startedAt, artifacts: [], symbols: symbols)
            try await releaseStorage.saveBuildMetadata(metadata, to: release)
            if let index = history.firstIndex(where: { $0.id == record.id }) {
                history[index].archivedSymbolFiles = symbols
                history[index].archiveStatus = .partial
                persistHistory()
            }
        } catch { /* The build error remains primary; symbols already written in the unique release directory are preserved. */ }
    }

    private static func makeMetadata(buildID: UUID, projectName: String, project: URL, configuration: BuildConfiguration, sdkLabel: String, service: FlutterBuildService, releaseStorage: ReleaseStorageService, result: BuildJobStatus, archiveResult: ReleaseArchiveStatus, duration: TimeInterval, createdAt: Date, artifacts: [ArchivedArtifact], symbols: [String]) async throws -> ReleaseMetadata {
        let executable = await service.selectedFlutterExecutable
        let git = await releaseStorage.gitContext(project: project)
        let dart: String?
        if let executable { dart = await releaseStorage.dartVersion(executable: executable, project: project) }
        else { dart = nil }
        let args = (try? configuration.arguments()) ?? []
        return ReleaseMetadata(
            schemaVersion: 1,
            buildID: buildID,
            projectID: ReleaseStorageService.stableProjectID(at: project, projectName: projectName),
            projectName: projectName,
            platform: configuration.platform,
            target: configuration.platform.target,
            flavor: configuration.flavor,
            entrypoint: configuration.entrypoint,
            buildName: configuration.buildName,
            buildNumber: configuration.buildNumber,
            flutterVersion: sdkLabel,
            flutterExecutablePath: executable?.path ?? "",
            dartVersion: dart,
            gitCommit: git.commit,
            gitBranch: git.branch,
            obfuscationEnabled: configuration.obfuscate,
            splitDebugInfoEnabled: configuration.obfuscate || configuration.generateDebugSymbols,
            createdAt: createdAt,
            durationSeconds: duration,
            buildResult: result,
            archiveResult: archiveResult,
            buildArguments: Self.redact(args),
            artifacts: artifacts,
            symbolFiles: symbols,
            warnings: []
        )
    }

    private static func redact(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var hideNext = false
        for argument in arguments {
            if hideNext { result.append("[REDACTED]"); hideNext = false; continue }
            result.append(argument)
            if argument == "--dart-define" || argument == "--dart-define-from-file" { hideNext = true }
        }
        return result
    }

    private func parseStage(_ text: String) {
        let line = text.lowercased()
        if line.contains("running gradle task") || line.contains("xcodebuild") { stage = .compiling }
        if line.contains("built build/") || line.contains("exporting") || line.contains("exporting ipa") { stage = .packaging }
        if let start = line.split(whereSeparator: \.isNewline).last { currentTask = String(start.prefix(180)) }
    }
    private func append(_ text: String, id: UUID) {
        var clean = text.replacingOccurrences(of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let record = history.first(where: { $0.id == id }) {
            for define in record.configuration.defines where !define.value.isEmpty {
                clean = clean.replacingOccurrences(of: define.value, with: "[REDACTED]")
            }
        }
        pendingLog += clean
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.flushLog(id: id)
        }
    }
    private func flushLog(id: UUID) {
        logFlushTask?.cancel(); logFlushTask = nil
        guard !pendingLog.isEmpty else { return }
        let chunk = pendingLog
        do { try activeLogHandle?.write(contentsOf: Data(chunk.utf8)) }
        catch { self.error = "Build output is visible, but its log file could not be updated: \(error.localizedDescription)" }
        liveLog = String((liveLog + chunk).suffix(2_000_000))
        pendingLog = ""
        if let index = history.firstIndex(where: { $0.id == id }) { history[index].log = liveLog }
        persistHistory()
    }
    private func update(_ id: UUID, stage: BuildStage, exitCode: Int32? = nil) { if let i = history.firstIndex(where: { $0.id == id }) { history[i].stage = stage; history[i].exitCode = exitCode }; persistHistory() }
    private func setExportError(_ id: UUID, _ message: String) { if let i = history.firstIndex(where: { $0.id == id }) { history[i].exportError = message }; persistHistory() }
    private func finish(_ id: UUID, status: BuildJobStatus, stage: BuildStage, artifact: String? = nil, exportedArtifact: String? = nil, exitCode: Int32? = nil, error: String? = nil) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].status = status; history[i].stage = stage; history[i].endedAt = Date(); history[i].artifactPath = artifact; history[i].exportedArtifactPath = exportedArtifact; history[i].exitCode = exitCode; history[i].error = error; history[i].log = liveLog
        persistHistory()
    }
    private func persistHistory() {
        var snapshot = Array(history.prefix(100))
        for index in snapshot.indices {
            snapshot[index].configuration.defines = snapshot[index].configuration.defines.map { BuildDefine(id: $0.id, key: $0.key, value: "") }
            if snapshot[index].logFilePath != nil { snapshot[index].log = "" }
        }
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: historyKey) }
    }
    private func persistPresets() {
        var snapshot = presets
        for projectID in snapshot.keys {
            snapshot[projectID] = snapshot[projectID]?.map { preset in
                var saved = preset
                saved.configuration.defines = saved.configuration.defines.map { BuildDefine(id: $0.id, key: $0.key, value: "") }
                return saved
            }
        }
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: presetsKey) }
    }
    func readLog(_ record: BuildHistoryRecord) -> String {
        guard let path = record.logFilePath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return record.log }
        return text
    }
    private static func makeLogFile(id: UUID) -> (url: URL, handle: FileHandle)? {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = base.appendingPathComponent("FVM GUI/Build Logs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(id.uuidString).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            return (url, try FileHandle(forWritingTo: url))
        } catch { return nil }
    }
    private static func findArtifact(project: URL, config: BuildConfiguration, since: Date) -> URL? {
        let directory: URL
        switch config.platform { case .androidAPK, .androidAAB: directory = project.appendingPathComponent("build/app/outputs"); case .iOSIPA: directory = project.appendingPathComponent("build/ios/ipa"); case .macOSApp: directory = project.appendingPathComponent("build/macos/Build/Products/\(config.buildMode.capitalized)") }
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let found = files.compactMap { $0 as? URL }.filter { $0.pathExtension == config.platform.fileExtension }.filter { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            return (date ?? .distantPast) >= since.addingTimeInterval(-2)
        }.sorted { ($0.pathExtension == "app" ? $0 : $0).lastPathComponent < $1.lastPathComponent }
        return found.last
    }
    private static func copyArtifact(_ source: URL, to directory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BuildValidationError("The selected export folder no longer exists or is not a folder.")
        }
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = source.deletingPathExtension().lastPathComponent + " (\(suffix))" + (source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)")
            destination = directory.appendingPathComponent(name); suffix += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
