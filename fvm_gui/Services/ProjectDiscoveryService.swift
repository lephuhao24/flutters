import Foundation

protocol ProjectDiscovering: Sendable {
    func scan(roots: [URL], maximumDepth: Int, ignoredPaths: Set<String>, progress: ProgressHandler?) async throws -> ProjectDiscoveryResult
}

actor ProjectDiscoveryService: ProjectDiscovering {
    private let fileSystem: any FileSystemOperating
    private let manifestReader: any ProjectManifestReading
    private let excludedPaths: Set<String>
    private let excludedNames: Set<String> = [".git", ".dart_tool", ".fvm", "build", "Pods", "node_modules"]

    init(fileSystem: any FileSystemOperating = LocalFileSystem(),
         manifestReader: any ProjectManifestReading = ProjectManifestReader(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileSystem = fileSystem
        self.manifestReader = manifestReader
        var excluded = Set<String>()
        if let custom = environment["FVM_CACHE_PATH"] { excluded.insert(URL(fileURLWithPath: custom).standardizedFileURL.path) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [home.appendingPathComponent("fvm/versions").path,
                     home.appendingPathComponent(".fvm/versions").path] { excluded.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
        excludedPaths = excluded
    }

    func scan(roots: [URL], maximumDepth: Int = 8, ignoredPaths: Set<String> = [], progress: ProgressHandler? = nil) async throws -> ProjectDiscoveryResult {
        var projectsByPath: [String: FlutterProject] = [:]
        var issuesByPath: [String: ProjectDiscoveryIssue] = [:]
        var scanned = 0
        let depthLimit = max(0, maximumDepth)
        let canonicalIgnored = Set(ignoredPaths.map(Self.canonicalPath))

        for selectedRoot in roots {
            try Task.checkCancellation()
            let root = selectedRoot.standardizedFileURL.resolvingSymlinksInPath()
            guard await fileSystem.isDirectory(root) else {
                issuesByPath[root.path] = ProjectDiscoveryIssue(id: root.path, message: "Selected directory is missing or inaccessible.")
                continue
            }
            var pending: [(URL, Int)] = [(root, 0)]
            var visited = Set<String>()
            while let (directory, depth) = pending.popLast() {
                try Task.checkCancellation()
                let canonical = Self.canonicalPath(directory)
                guard Self.isInside(canonical, root: root.path), !excludedPaths.contains(where: { Self.isInside(canonical, root: $0) }),
                      visited.insert(canonical).inserted else { continue }
                scanned += 1
                if await fileSystem.exists(directory.appendingPathComponent("pubspec.yaml")) {
                    do {
                        let project = try await manifestReader.read(directory, within: root)
                        if !canonicalIgnored.contains(project.path) {
                            if let existing = projectsByPath[project.path] {
                                // Prefer the nearest discovered config when overlapping roots have different boundaries.
                                let existingDepth = existing.configurationSource.map { URL(fileURLWithPath: $0).pathComponents.count } ?? -1
                                let newDepth = project.configurationSource.map { URL(fileURLWithPath: $0).pathComponents.count } ?? -1
                                if newDepth > existingDepth { projectsByPath[project.path] = project }
                            } else { projectsByPath[project.path] = project }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { issuesByPath[canonical] = ProjectDiscoveryIssue(id: canonical, message: error.localizedDescription) }
                }
                guard depth < depthLimit else { continue }
                let children: [FileSystemEntry]
                do { children = try await fileSystem.contents(of: directory) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if directory != root { issuesByPath[canonical] = ProjectDiscoveryIssue(id: canonical, message: "Cannot read directory: \(error.localizedDescription)") }
                    else { issuesByPath[canonical] = ProjectDiscoveryIssue(id: canonical, message: "Cannot read selected directory: \(error.localizedDescription)") }
                    continue
                }
                for child in children where child.isDirectory && !child.isSymbolicLink && !excludedNames.contains(child.url.lastPathComponent) {
                    let childPath = Self.canonicalPath(child.url)
                    guard Self.isInside(childPath, root: root.path), !excludedPaths.contains(where: { Self.isInside(childPath, root: $0) }) else { continue }
                    pending.append((child.url, depth + 1))
                }
                if scanned == 1 || scanned.isMultiple(of: 20) {
                    await progress?(OperationProgress(message: "Scanned \(scanned) folders · found \(projectsByPath.count) projects"))
                }
            }
        }
        try Task.checkCancellation()
        return ProjectDiscoveryResult(projects: projectsByPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                                      issues: issuesByPath.values.sorted { $0.id < $1.id }, scannedDirectories: scanned)
    }

    private static func canonicalPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private static func canonicalPath(_ path: String) -> String { canonicalPath(URL(fileURLWithPath: path)) }
    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
