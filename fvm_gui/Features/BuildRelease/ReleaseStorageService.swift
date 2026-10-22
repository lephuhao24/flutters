import Foundation
import CryptoKit
import ZIPFoundation

final class ReleaseStorageDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}

struct ReleaseStorageLocation: Codable, Hashable, Sendable {
    let projectID: String
    let buildID: UUID
    let rootURL: URL

    var artifactsURL: URL { rootURL.appendingPathComponent("artifacts", isDirectory: true) }
    var symbolsURL: URL { rootURL.appendingPathComponent("symbols", isDirectory: true) }
    var logsURL: URL { rootURL.appendingPathComponent("logs", isDirectory: true) }
    var metadataURL: URL { rootURL.appendingPathComponent("build-info.json") }
}

struct ArchivedArtifact: Codable, Hashable, Sendable, Identifiable {
    var id: String { relativePath }
    let relativePath: String
    let fileName: String
    let sizeBytes: Int64
    let isDirectory: Bool
}

struct ReleaseMetadata: Codable, Sendable {
    let schemaVersion: Int
    let buildID: UUID
    let projectID: String
    let projectName: String
    let platform: ReleasePlatform
    let target: String
    let flavor: String?
    let entrypoint: String
    let buildName: String
    let buildNumber: String
    let flutterVersion: String
    let flutterExecutablePath: String
    let dartVersion: String?
    let gitCommit: String?
    let gitBranch: String?
    let obfuscationEnabled: Bool
    let splitDebugInfoEnabled: Bool
    let createdAt: Date
    let durationSeconds: TimeInterval?
    let buildResult: BuildJobStatus
    let archiveResult: ReleaseArchiveStatus
    let buildArguments: [String]
    let artifacts: [ArchivedArtifact]
    let symbolFiles: [String]
    let warnings: [String]
}

struct ArchivedRelease: Codable, Sendable, Identifiable {
    var id: UUID { metadata.buildID }
    let directoryURL: URL
    let metadata: ReleaseMetadata
}

enum ReleaseExportContents: Sendable {
    case artifactsOnly
    case artifactsAndMetadata
    case complete
}

enum ReleaseStorageError: LocalizedError, Sendable {
    case invalidDirectory(String)
    case releaseAlreadyExists(URL)
    case noArtifacts
    case destinationExists(URL)
    case metadataUnavailable
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path): "The release storage directory is unavailable or not writable: \(path)"
        case .releaseAlreadyExists(let url): "A release already exists at \(url.path). Nothing was overwritten."
        case .noArtifacts: "No Flutter build artifacts were found to archive."
        case .destinationExists(let url): "The destination already exists: \(url.path). Choose another destination."
        case .metadataUnavailable: "The archived release metadata could not be read."
        case .unsafePath: "A release path contained an invalid filesystem component."
        }
    }
}

actor ReleaseStorageService {
    static let customPathKey = "buildRelease.storage.customPath.v1"
    static let bookmarkKey = "buildRelease.storage.bookmark.v1"
    static let bookmarkRegistryKey = "buildRelease.storage.bookmarksByPath.v1"
    static let appSupportDirectoryKey = "buildRelease.storage.directoryName.v1"
    static let directoryName = "Releases"
    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    init(defaultsBox: ReleaseStorageDefaults = ReleaseStorageDefaults(.standard)) {
        self.defaults = defaultsBox.value
    }

    static func defaultStorageURL(fileManager: FileManager = .default, bundle: Bundle = .main) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundle.bundleIdentifier?.split(separator: ".").last.map(String.init)
            ?? "Application"
        return support.appendingPathComponent(appName, isDirectory: true).appendingPathComponent(directoryName, isDirectory: true)
    }

    func configuredStorageURL() throws -> URL {
        try resolveStorageRoot().url
    }

    func configureStorageLocation(_ url: URL, bookmark: Data?) throws {
        let canonicalPath = url.standardizedFileURL.path
        defaults.set(canonicalPath, forKey: Self.customPathKey)
        if let bookmark {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            var registry = defaults.dictionary(forKey: Self.bookmarkRegistryKey) as? [String: Data] ?? [:]
            registry[canonicalPath] = bookmark
            defaults.set(registry, forKey: Self.bookmarkRegistryKey)
        }
        else { defaults.removeObject(forKey: Self.bookmarkKey) }
    }

    func resetStorageLocation() {
        defaults.removeObject(forKey: Self.customPathKey)
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    func prepareReleaseDirectory(
        for configuration: BuildConfiguration,
        project: URL,
        projectName: String,
        buildID: UUID
    ) async throws -> ReleaseStorageLocation {
        let (root, scoped) = try resolveStorageRoot()
        let hasAccess = scoped && root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let projectID = Self.stableProjectID(at: project, projectName: projectName)
            let releaseURL = Self.previewReleaseURL(root: root, configuration: configuration, project: project, projectName: projectName, buildID: buildID)
            let parent = releaseURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: releaseURL.path) else { throw ReleaseStorageError.releaseAlreadyExists(releaseURL) }
            try fileManager.createDirectory(at: releaseURL, withIntermediateDirectories: false)
            let location = ReleaseStorageLocation(projectID: projectID, buildID: buildID, rootURL: releaseURL)
            try fileManager.createDirectory(at: location.artifactsURL, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: location.symbolsURL, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: location.logsURL, withIntermediateDirectories: false)
            return location
        } catch let error as ReleaseStorageError { throw error }
        catch { throw ReleaseStorageError.invalidDirectory(error.localizedDescription) }
    }

    func withStorageAccess<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let (root, scoped) = try resolveStorageRoot()
        let hasAccess = scoped && root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }
        return try await operation()
    }

    func withStorageAccess<T: Sendable>(to url: URL, operation: @Sendable () async throws -> T) async throws -> T {
        let (scopeURL, scoped) = try resolveAccessRoot(for: url)
        let hasAccess = scoped && scopeURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { scopeURL.stopAccessingSecurityScopedResource() } }
        return try await operation()
    }

    func archiveArtifacts(_ sources: [URL], to release: ReleaseStorageLocation) throws -> [ArchivedArtifact] {
        guard !sources.isEmpty else { throw ReleaseStorageError.noArtifacts }
        var archived: [ArchivedArtifact] = []
        for source in sources {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = release.artifactsURL.appendingPathComponent(source.lastPathComponent, isDirectory: (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            guard !fileManager.fileExists(atPath: destination.path) else { throw ReleaseStorageError.destinationExists(destination) }
            try fileManager.copyItem(at: source, to: destination)
            let sourceSize = try Self.size(of: source)
            let copiedSize = try Self.size(of: destination)
            guard sourceSize == copiedSize else {
                try? fileManager.removeItem(at: destination)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            archived.append(ArchivedArtifact(
                relativePath: "artifacts/\(source.lastPathComponent)",
                fileName: source.lastPathComponent,
                sizeBytes: copiedSize,
                isDirectory: (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ))
        }
        guard !archived.isEmpty else { throw ReleaseStorageError.noArtifacts }
        return archived
    }

    func discoverSymbols(in release: ReleaseStorageLocation) throws -> [String] {
        guard let enumerator = fileManager.enumerator(at: release.symbolsURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var symbols: [String] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let baseComponents = release.symbolsURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let fileComponents = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let relativeComponents = fileComponents.starts(with: baseComponents) ? Array(fileComponents.dropFirst(baseComponents.count)) : [url.lastPathComponent]
            symbols.append("symbols/" + relativeComponents.joined(separator: "/"))
        }
        return symbols.sorted()
    }

    func archiveBuildLog(from source: URL?, text: String, to release: ReleaseStorageLocation) throws -> String? {
        let destination = release.logsURL.appendingPathComponent("build.log")
        if let source, fileManager.fileExists(atPath: source.path) {
            guard !fileManager.fileExists(atPath: destination.path) else { throw ReleaseStorageError.destinationExists(destination) }
            try fileManager.copyItem(at: source, to: destination)
        } else {
            try Data(text.utf8).write(to: destination, options: .atomic)
        }
        return "logs/build.log"
    }

    func saveBuildMetadata(_ metadata: ReleaseMetadata, to release: ReleaseStorageLocation) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: release.metadataURL, options: .atomic)
        let verify = try Data(contentsOf: release.metadataURL)
        _ = try JSONDecoder.iso8601.decode(ReleaseMetadata.self, from: verify)
    }

    func loadMetadata(at releaseURL: URL) throws -> ReleaseMetadata {
        try withCurrentStorageAccess(for: releaseURL) {
            let url = releaseURL.appendingPathComponent("build-info.json")
            guard let data = try? Data(contentsOf: url) else { throw ReleaseStorageError.metadataUnavailable }
            return try JSONDecoder.iso8601.decode(ReleaseMetadata.self, from: data)
        }
    }

    func listReleases(for projectID: String? = nil) async throws -> [ArchivedRelease] {
        let (root, scoped) = try resolveStorageRoot()
        let hasAccess = scoped && root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }
        let searchRoot = projectID.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        return scanReleases(at: searchRoot)
    }

    func storageStatistics() async throws -> (releaseCount: Int, sizeBytes: Int64) {
        let (root, scoped) = try resolveStorageRoot()
        let hasAccess = scoped && root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: root.path) else { return (0, 0) }
        let releases = try await listReleases(for: nil)
        return (releases.count, try Self.size(of: root))
    }

    func locateArtifacts(project: URL, configuration: BuildConfiguration, since: Date) throws -> [URL] {
        let directory: URL
        switch configuration.platform {
        case .androidAPK, .androidAAB: directory = project.appendingPathComponent("build/app/outputs", isDirectory: true)
        case .iOSIPA: directory = project.appendingPathComponent("build/ios/ipa", isDirectory: true)
        case .macOSApp: directory = project.appendingPathComponent("build/macos/Build/Products/\(configuration.buildMode.capitalized)", isDirectory: true)
        }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.pathExtension == configuration.platform.fileExtension else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            guard (date ?? .distantPast) >= since.addingTimeInterval(-2) else { continue }
            found.append(url)
            if configuration.platform == .macOSApp { enumerator.skipDescendants() }
        }
        return found.sorted { $0.path < $1.path }
    }

    func gitContext(project: URL) -> (commit: String?, branch: String?) {
        (runGit(["rev-parse", "HEAD"], at: project), runGit(["branch", "--show-current"], at: project))
    }

    func dartVersion(executable: URL, project: URL) -> String? {
        guard let output = runProcess(executable: executable, arguments: ["--version"], directory: project), !output.isEmpty else { return nil }
        return output.components(separatedBy: .newlines).first(where: { $0.localizedCaseInsensitiveContains("dart") })?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeRelease(at url: URL) throws {
        try withCurrentStorageAccess(for: url) {
            guard url.lastPathComponent.count == 36, UUID(uuidString: url.lastPathComponent) != nil,
                  url.lastPathComponent == url.lastPathComponent.lowercased() else { throw ReleaseStorageError.unsafePath }
            try fileManager.removeItem(at: url)
        }
    }

    func exportRelease(at releaseURL: URL, destination: URL, contents: ReleaseExportContents) throws {
        try withCurrentStorageAccess(for: releaseURL) {
        let destinationParent = destination.deletingLastPathComponent()
        let destinationScoped = destinationParent.startAccessingSecurityScopedResource()
        defer { if destinationScoped { destinationParent.stopAccessingSecurityScopedResource() } }
        guard !fileManager.fileExists(atPath: destination.path) else { throw ReleaseStorageError.destinationExists(destination) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.zip")
        defer { try? fileManager.removeItem(at: staging) }
        let archive = try Archive(url: staging, accessMode: .create)
        guard let enumerator = fileManager.enumerator(at: releaseURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw ReleaseStorageError.metadataUnavailable }
        var entryCount = 0
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard let relative = Self.relativePath(of: fileURL, inside: releaseURL) else { continue }
            guard Self.includes(relativePath: relative, contents: contents) else { continue }
            try archive.addEntry(with: relative, fileURL: fileURL, compressionMethod: .deflate)
            entryCount += 1
        }
        guard entryCount > 0 else { throw ReleaseStorageError.noArtifacts }
        guard fileManager.fileExists(atPath: staging.path) else { throw CocoaError(.fileWriteUnknown) }
        let verifiedArchive = try Archive(url: staging, accessMode: .read)
        let verifiedCount = verifiedArchive.reduce(into: 0) { count, _ in count += 1 }
        guard verifiedCount == entryCount else { throw CocoaError(.fileReadCorruptFile) }
        try fileManager.moveItem(at: staging, to: destination)
        }
    }

    func exportReleaseFolder(at releaseURL: URL, to destination: URL, contents: ReleaseExportContents) throws {
        try withCurrentStorageAccess(for: releaseURL) {
        let destinationScoped = destination.startAccessingSecurityScopedResource()
        defer { if destinationScoped { destination.stopAccessingSecurityScopedResource() } }
        guard !fileManager.fileExists(atPath: destination.path) else { throw ReleaseStorageError.destinationExists(destination) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        guard let enumerator = fileManager.enumerator(at: releaseURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw ReleaseStorageError.metadataUnavailable }
        for case let source as URL in enumerator {
            try Task.checkCancellation()
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard let relative = Self.relativePath(of: source, inside: releaseURL) else { continue }
            guard Self.includes(relativePath: relative, contents: contents) else { continue }
            let target = staging.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
        }
        guard try Self.size(of: staging) > 0 else { throw ReleaseStorageError.noArtifacts }
        try fileManager.moveItem(at: staging, to: destination)
        }
    }

    func deleteReleasesRoot(at root: URL) throws {
        try fileManager.removeItem(at: root)
    }

    func migrateArchives(from source: URL, to destination: URL) async throws {
        let sourceCanonical = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationCanonical = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard sourceCanonical != destinationCanonical,
              !destinationCanonical.path.hasPrefix(sourceCanonical.path + "/"),
              !sourceCanonical.path.hasPrefix(destinationCanonical.path + "/") else { throw ReleaseStorageError.unsafePath }
        let sourceScoped = source.startAccessingSecurityScopedResource()
        let destinationScoped = destination.startAccessingSecurityScopedResource()
        let sourceParentScoped = source.deletingLastPathComponent().startAccessingSecurityScopedResource()
        defer {
            if sourceScoped { source.stopAccessingSecurityScopedResource() }
            if destinationScoped { destination.stopAccessingSecurityScopedResource() }
            if sourceParentScoped { source.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
        }
        let requiredBytes = try Self.size(of: source)
        if let available = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available < requiredBytes {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".release-migration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for child in children {
                try Task.checkCancellation()
                try fileManager.copyItem(at: child, to: staging.appendingPathComponent(child.lastPathComponent))
            }
            let sourceSize = try Self.size(of: source)
            let stagedSize = try Self.size(of: staging)
            guard sourceSize == stagedSize else { throw CocoaError(.fileWriteUnknown) }
            for child in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let target = destination.appendingPathComponent(child.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) {
                    guard try Self.size(of: child) == Self.size(of: target) else { throw ReleaseStorageError.destinationExists(target) }
                    try fileManager.removeItem(at: child)
                } else {
                    try fileManager.moveItem(at: child, to: target)
                }
            }
            try fileManager.removeItem(at: staging)
            try fileManager.removeItem(at: source)
        } catch {
            // Keep staging data so a failed migration can be recovered manually.
            throw error
        }
    }

    static func stableProjectID(at project: URL, projectName: String) -> String {
        let canonical = project.standardizedFileURL.resolvingSymlinksInPath()
        let manifest = (try? String(contentsOf: canonical.appendingPathComponent("pubspec.yaml"), encoding: .utf8)) ?? ""
        let packageName = manifest.components(separatedBy: .newlines).first(where: { $0.hasPrefix("name:") })?.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines) ?? projectName
        let gitRoot = Self.gitRoot(containing: canonical)
        let remote = gitRoot.flatMap(Self.gitOriginURL(at:))
        let identity = [remote ?? "", String(packageName), gitRoot == nil ? canonical.path : ""].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "project-\(digest.prefix(24))"
    }

    static func previewReleaseURL(root: URL, configuration: BuildConfiguration, project: URL, projectName: String, buildID: UUID) -> URL {
        let projectID = stableProjectID(at: project, projectName: projectName)
        return root
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(configuration.platform.rawValue, isDirectory: true)
            .appendingPathComponent(safeComponent(configuration.flavor ?? "default"), isDirectory: true)
            .appendingPathComponent(safeComponent(versionComponent(configuration)), isDirectory: true)
            .appendingPathComponent(buildID.uuidString.lowercased(), isDirectory: true)
    }

    static func safeComponent(_ input: String) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+"))
        let encoded = String(normalized.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return encoded.isEmpty ? "default" : String(encoded.prefix(96))
    }

    private func resolveStorageRoot() throws -> (url: URL, scoped: Bool) {
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(refreshed, forKey: Self.bookmarkKey)
                }
                return (resolved, true)
            }
            throw ReleaseStorageError.invalidDirectory("The saved security-scoped bookmark is unavailable. Re-select the release storage folder in Settings.")
        }
        if let path = defaults.string(forKey: Self.customPathKey), !path.isEmpty {
            return (URL(fileURLWithPath: path, isDirectory: true), false)
        }
        return (try Self.defaultStorageURL(), false)
    }

    private func resolveAccessRoot(for target: URL) throws -> (url: URL, scoped: Bool) {
        let targetPath = target.standardizedFileURL.path
        let registry = defaults.dictionary(forKey: Self.bookmarkRegistryKey) as? [String: Data] ?? [:]
        let match = registry.keys
            .filter { targetPath == $0 || targetPath.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        if let match, let data = registry[match] {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                throw ReleaseStorageError.invalidDirectory("The saved security-scoped bookmark for \(match) is unavailable. Re-select that folder in Settings.")
            }
            if stale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                var updated = registry
                updated[match] = refreshed
                defaults.set(updated, forKey: Self.bookmarkRegistryKey)
            }
            return (resolved, true)
        }
        return try resolveStorageRoot()
    }

    private func withCurrentStorageAccess<T>(for target: URL? = nil, _ operation: () throws -> T) throws -> T {
        let (root, scoped) = try target.map { try resolveAccessRoot(for: $0) } ?? resolveStorageRoot()
        let hasAccess = scoped && root.startAccessingSecurityScopedResource()
        defer { if hasAccess { root.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private func scanReleases(at root: URL) -> [ArchivedRelease] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [ArchivedRelease] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == "build-info.json" else { continue }
            guard let data = try? Data(contentsOf: url), let metadata = try? JSONDecoder.iso8601.decode(ReleaseMetadata.self, from: data) else { continue }
            results.append(ArchivedRelease(directoryURL: url.deletingLastPathComponent(), metadata: metadata))
        }
        return results.sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }

    private static func versionComponent(_ config: BuildConfiguration) -> String {
        let name = config.buildName.isEmpty ? "unversioned" : config.buildName
        return config.buildNumber.isEmpty ? name : "\(name)+\(config.buildNumber)"
    }

    private static func size(of url: URL) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator where (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func includes(relativePath: String, contents: ReleaseExportContents) -> Bool {
        switch contents {
        case .artifactsOnly: relativePath.hasPrefix("artifacts/")
        case .artifactsAndMetadata: relativePath.hasPrefix("artifacts/") || relativePath == "build-info.json"
        case .complete: true
        }
    }

    private static func relativePath(of file: URL, inside directory: URL) -> String? {
        let rootComponents = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let fileComponents = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.starts(with: rootComponents) else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func gitRoot(containing project: URL) -> URL? {
        var current = project
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func gitOriginURL(at root: URL) -> String? {
        let gitPath = root.appendingPathComponent(".git")
        let gitDirectory: URL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory), isDirectory.boolValue {
            gitDirectory = gitPath
        } else if let text = try? String(contentsOf: gitPath, encoding: .utf8), let range = text.range(of: #"gitdir:\s*(.+)"#, options: .regularExpression) {
            let match = String(text[range]).replacingOccurrences(of: #"^gitdir:\s*"#, with: "", options: .regularExpression)
            gitDirectory = URL(fileURLWithPath: match, relativeTo: root).standardizedFileURL
        } else { return nil }
        guard let config = try? String(contentsOf: gitDirectory.appendingPathComponent("config"), encoding: .utf8),
              let section = config.range(of: #"(?ms)^\[remote "origin"\](.*?)(?=^\[|\z)"#, options: .regularExpression) else { return nil }
        let text = String(config[section])
        guard let match = text.range(of: #"(?m)^\s*url\s*=\s*(.+)$"#, options: .regularExpression) else { return nil }
        return String(text[match]).replacingOccurrences(of: #"(?m)^\s*url\s*=\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ arguments: [String], at directory: URL) -> String? {
        guard let git = URL(fileURLWithPath: "/usr/bin/git", isDirectory: false) as URL?,
              let result = Self.run(executable: git, arguments: ["-C", directory.path] + arguments),
              result.status == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func runProcess(executable: URL, arguments: [String], directory: URL) -> String? {
        Self.run(executable: executable, arguments: arguments, directory: directory)?.output
    }

    private static func run(executable: URL, arguments: [String], directory: URL? = nil) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return nil }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
