import Foundation

actor ProjectExportService {
    private static let sensitiveNames: Set<String> = [
        ".env", ".netrc", ".npmrc", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        "credentials.json", "credentials.yaml", "credentials.yml", "secrets.json", "secrets.yaml", "secrets.yml"
    ]
    private let git: GitIgnoreService
    private let archiveService: ProjectArchiveService
    private let fileManager: FileManager

    init(git: GitIgnoreService = GitIgnoreService(), archiveService: ProjectArchiveService = ProjectArchiveService(), fileManager: FileManager = .default) {
        self.git = git
        self.archiveService = archiveService
        self.fileManager = fileManager
    }

    func createArchive(manifest: ExportManifest, destination: URL, compression: ExportCompression,
                       replaceExisting: Bool = false,
                       report: @escaping @Sendable (ExportProgress) async -> Void) async throws -> ExportReceipt {
        try validate(manifest)
        return try await archiveService.createArchive(manifest: manifest, destination: destination,
                                                       compression: compression, replaceExisting: replaceExisting,
                                                       report: report)
    }

    func preview(project: FlutterProject, options: ExportOptions, destination: URL?,
                 report: @escaping @Sendable (ExportProgress) async -> Void = { _ in }) async throws -> ExportManifest {
        let inputRoot = URL(fileURLWithPath: project.path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectExportError.invalidProjectRoot
        }
        let root = inputRoot.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        try Task.checkCancellation()
        await report(ExportProgress(stage: .scanning, currentPath: root.lastPathComponent, filesCompleted: 0,
                                    totalFiles: 0, bytesProcessed: 0, totalBytes: 0))
        let listing: GitFileListing
        listing = try await git.listFiles(root: root, includeUntracked: options.includeUntrackedFiles,
                                          respectIgnore: options.respectGitIgnore)
        var warnings: [String] = []
        if !options.respectGitIgnore { warnings.append("Git ignore handling is disabled; ignored files may be included.") }
        if let warning = listing.warning { warnings.append(warning) }
        let candidates: [String]
        if let paths = listing.paths { candidates = paths }
        else { candidates = try scanPaths(root: root, excludeGit: options.excludeGitDirectory, warnings: &warnings) }
        await report(ExportProgress(stage: .buildingManifest, currentPath: nil, filesCompleted: 0,
                                    totalFiles: candidates.count, bytesProcessed: 0, totalBytes: 0))

        var entries: [ExportFileEntry] = []
        var excluded = 0
        var sensitive: [String] = []
        var seen = Set<String>()
        let destinationPath = destination.map(Self.normalizedDestinationPath)
        for relative in candidates {
            try Task.checkCancellation()
            guard Self.isSafeRelativePath(relative) else { excluded += 1; warnings.append("Skipped unsafe path from file enumeration."); continue }
            guard seen.insert(relative).inserted else { excluded += 1; continue }
            if options.excludeGitDirectory && relative.split(separator: "/").contains(".git") { excluded += 1; continue }
            if options.excludeFlutterCaches && Self.isFlutterCache(relative) { excluded += 1; continue }
            if options.excludedSensitivePaths.contains(relative) { excluded += 1; continue }
            let source = URL(fileURLWithPath: root.path + "/" + relative).standardizedFileURL
            guard Self.isContained(source, in: root), destinationPath != source.path else { excluded += 1; continue }
            do {
                guard try !Self.containsSymlink(source, root: root, fileManager: fileManager) else {
                    excluded += 1
                    warnings.append("Symbolic link excluded for safety: \(relative)")
                    continue
                }
                let attributes = try fileManager.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { excluded += 1; continue }
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                let device = attributes[.systemNumber].map(String.init(describing:))
                let inode = attributes[.systemFileNumber].map(String.init(describing:))
                let identifier: String? = if let device, let inode { device + ":" + inode } else { nil }
                entries.append(ExportFileEntry(relativePath: relative, sourceURL: source, size: size, modifiedAt: modified, fileIdentifier: identifier))
                if Self.isSensitive(relative) { sensitive.append(relative) }
            } catch {
                excluded += 1
                warnings.append("Could not read file metadata for \(relative): \(error.localizedDescription)")
            }
        }
        entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        guard !entries.isEmpty else { throw ProjectExportError.noFiles }
        let total = entries.reduce(Int64.zero) { $0 &+ $1.size }
        var uniqueWarnings: [String] = []
        for warning in warnings where !uniqueWarnings.contains(warning) { uniqueWarnings.append(warning) }
        return ExportManifest(projectRoot: root, files: entries, totalBytes: total, excludedFileCount: excluded,
                              sensitivePaths: sensitive.sorted(), warnings: uniqueWarnings,
                              usedGitIgnore: options.respectGitIgnore && listing.paths != nil)
    }

    func validate(_ manifest: ExportManifest) throws {
        try Task.checkCancellation()
        for entry in manifest.files {
            guard Self.isSafeRelativePath(entry.relativePath), Self.isContained(entry.sourceURL, in: manifest.projectRoot) else {
                throw ProjectExportError.unsafePath(entry.relativePath)
            }
            do {
                guard try !Self.containsSymlink(entry.sourceURL, root: manifest.projectRoot, fileManager: fileManager) else {
                    throw ProjectExportError.unsafePath(entry.relativePath)
                }
                let attributes = try fileManager.attributesOfItem(atPath: entry.sourceURL.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                let modified = attributes[.modificationDate] as? Date
                let device = attributes[.systemNumber].map(String.init(describing:)) ?? ""
                let inode = attributes[.systemFileNumber].map(String.init(describing:)) ?? ""
                guard size == entry.size, modified == entry.modifiedAt,
                      (device + ":" + inode == entry.fileIdentifier || entry.fileIdentifier == nil) else {
                    throw ProjectExportError.fileChanged(entry.relativePath)
                }
            } catch let error as ProjectExportError { throw error }
            catch { throw ProjectExportError.fileChanged(entry.relativePath) }
        }
    }

    private func scanPaths(root: URL, excludeGit: Bool, warnings: inout [String]) throws -> [String] {
        var result: [String] = []
        var stack: [(url: URL, relativePath: String)] = [(root, "")]
        while let (directory, parentRelativePath) = stack.popLast() {
            try Task.checkCancellation()
            let children: [URL]
            do { children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) }
            catch { warnings.append("Could not read directory \(directory.path): \(error.localizedDescription)"); continue }
            for child in children {
                try Task.checkCancellation()
                let relative = parentRelativePath.isEmpty ? child.lastPathComponent : parentRelativePath + "/" + child.lastPathComponent
                guard Self.isSafeRelativePath(relative) else { continue }
                if excludeGit && child.lastPathComponent == ".git" { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    warnings.append("Symbolic link excluded for safety: \(relative)")
                } else if values?.isDirectory == true {
                    if excludeGit && child.lastPathComponent == ".git" { continue }
                    if Self.isFlutterCacheDirectory(relative) { continue }
                    stack.append((child, relative))
                } else {
                    result.append(relative)
                }
            }
        }
        return result
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    private static func isContained(_ file: URL, in root: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func containsSymlink(_ file: URL, root: URL, fileManager: FileManager) throws -> Bool {
        let relative = String(file.path.dropFirst(root.path.count + 1))
        var cursor = root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let attrs = try fileManager.attributesOfItem(atPath: cursor.path)
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return true }
        }
        return false
    }

    private static func normalizedDestinationPath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    private static func isFlutterCache(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        let directories = Set([".dart_tool", ".fvm", ".gradle", "Pods", "node_modules"])
        if components.contains(where: directories.contains) { return true }
        if components.first == "build" { return true }
        if components.count >= 3, components[0] == "android", components[2] == "build" { return true }
        if components.count >= 3, ["ios", "macos", "linux", "windows"].contains(components[0]),
           components[1] == "Flutter", components[2] == "ephemeral" { return true }
        let name = components.last ?? ""
        return name == ".DS_Store" || [".flutter-plugins", ".flutter-plugins-dependencies", ".packages"].contains(name)
    }

    private static func isFlutterCacheDirectory(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { [".dart_tool", ".fvm", ".gradle", "Pods", "node_modules"].contains($0) }) { return true }
        if components.first == "build" { return true }
        if components.count >= 3, components[0] == "android", components[2] == "build" { return true }
        return components.count >= 3 && ["ios", "macos", "linux", "windows"].contains(components[0]) &&
            components[1] == "Flutter" && components[2] == "ephemeral"
    }

    private static func isSensitive(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let ext = URL(fileURLWithPath: name).pathExtension
        if ["p12", "p8", "jks", "keystore", "pem", "key", "pfx"].contains(ext) { return true }
        if sensitiveNames.contains(name) || name.hasPrefix(".env.") { return true }
        return name.contains("service-account") && ext == "json"
    }
}
