import Darwin
import Foundation

protocol SDKStorageServicing: Sendable {
    func analyze(sdks: [FlutterSDK], registeredProjects: [FlutterProject], discoveredProjects: [FlutterProject], forceRefresh: Bool) async throws -> SDKStorageAnalysis
}

actor SDKStorageService: SDKStorageServicing {
    private struct CachedUsage: Sendable {
        let usage: SDKDirectoryUsage
        let scannedAt: Date
    }

    private var cache: [String: CachedUsage] = [:]
    private var inFlight: [String: Task<SDKDirectoryUsage, any Error>] = [:]
    private let cacheLifetime: TimeInterval

    init(cacheLifetime: TimeInterval = 30) { self.cacheLifetime = cacheLifetime }

    func analyze(sdks: [FlutterSDK], registeredProjects: [FlutterProject], discoveredProjects: [FlutterProject], forceRefresh: Bool = false) async throws -> SDKStorageAnalysis {
        var registeredByPath: [String: FlutterProject] = [:]
        for project in registeredProjects { registeredByPath[Self.canonicalPath(project.path)] = project }
        var discoveredByPath: [String: FlutterProject] = [:]
        for project in discoveredProjects {
            let path = Self.canonicalPath(project.path)
            if registeredByPath[path] == nil { discoveredByPath[path] = project }
        }

        var items: [SDKStorageItem] = []
        var validCacheKeys = Set<String>()
        var seenSDKDirectories = Set<String>()
        for sdk in sdks {
            try Task.checkCancellation()
            let directory = Self.canonicalPath(sdk.directory)
            guard seenSDKDirectories.insert(directory).inserted else { continue }
            let cacheKey = sdk.name + "\0" + directory
            validCacheKeys.insert(cacheKey)
            let usage: SDKDirectoryUsage
            if !forceRefresh, let cached = cache[cacheKey], Date().timeIntervalSince(cached.scannedAt) < cacheLifetime {
                usage = cached.usage
            } else {
                let scan: Task<SDKDirectoryUsage, any Error>
                if let running = inFlight[cacheKey] {
                    scan = running
                } else {
                    scan = Task.detached(priority: .utility) { try Self.measureDirectory(at: directory) }
                    inFlight[cacheKey] = scan
                }
                do {
                    usage = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                    cache[cacheKey] = CachedUsage(usage: usage, scannedAt: Date())
                    inFlight[cacheKey] = nil
                } catch is CancellationError {
                    inFlight[cacheKey] = nil
                    throw CancellationError()
                }
                catch {
                    inFlight[cacheKey] = nil
                    items.append(SDKStorageItem(version: sdk.name, directory: directory, logicalSize: 0, allocatedSize: nil,
                                                isGlobal: sdk.isGlobal, registeredProjectReferenceCount: 0, discoveredProjectReferenceCount: 0,
                                                measurementIssue: error.localizedDescription))
                    continue
                }
            }
            let registeredCount = registeredByPath.values.filter { Self.references($0, sdk: sdk) }.count
            let discoveredCount = discoveredByPath.values.filter { Self.references($0, sdk: sdk) }.count
            items.append(SDKStorageItem(version: sdk.name, directory: directory, logicalSize: usage.logicalSize,
                                        allocatedSize: usage.allocatedSize, isGlobal: sdk.isGlobal,
                                        registeredProjectReferenceCount: registeredCount, discoveredProjectReferenceCount: discoveredCount))
        }
        cache = cache.filter { validCacheKeys.contains($0.key) }
        try Task.checkCancellation()
        let unreferenced = items.filter { $0.projectReferenceCount == 0 }.reduce(UInt64.zero) { Self.saturatedAdd($0, $1.measuredSize) }
        let cleanup = items.filter(\.isCleanupCandidate).reduce(UInt64.zero) { Self.saturatedAdd($0, $1.measuredSize) }
        return SDKStorageAnalysis(items: items.sorted { $0.version.localizedStandardCompare($1.version) == .orderedAscending },
                                  storageWithoutKnownReferences: unreferenced, potentialCleanupSpace: cleanup,
                                  allocatedSizeAvailable: items.allSatisfy { $0.allocatedSize != nil || $0.measurementIssue != nil }, measuredAt: Date())
    }

    private static func references(_ project: FlutterProject, sdk: FlutterSDK) -> Bool {
        guard project.type != .dartPackage else { return false }
        let configured = project.configuredVersion ?? project.version
        return configured == sdk.name || configured == sdk.flutterSdkVersion
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    /// Walks using lstat so nested symlinks are never followed. Device/inode pairs
    /// ensure hard-linked files are counted once within an SDK tree.
    nonisolated private static func measureDirectory(at path: String) throws -> SDKDirectoryUsage {
        try Task.checkCancellation()
        var rootInfo = stat()
        let rootStatus = path.withCString { lstat($0, &rootInfo) }
        guard rootStatus == 0 else {
            if errno == ENOENT { throw SDKStorageError.missingDirectory(path) }
            throw SDKStorageError.unreadableDirectory(path, String(cString: strerror(errno)))
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else { throw SDKStorageError.unreadableDirectory(path, "The SDK path is not a directory.") }

        var pending = [URL(fileURLWithPath: path, isDirectory: true)]
        var seenFiles = Set<String>()
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) }
            catch {
                throw SDKStorageError.unreadableDirectory(directory.path, error.localizedDescription)
            }
            for child in children {
                try Task.checkCancellation()
                var info = stat()
                let status = child.path.withCString { lstat($0, &info) }
                guard status == 0 else { throw SDKStorageError.unreadableDirectory(child.path, String(cString: strerror(errno))) }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFLNK { continue }
                if kind == S_IFDIR { pending.append(child); continue }
                guard kind == S_IFREG else { continue }
                let identity = "\(info.st_dev):\(info.st_ino)"
                guard seenFiles.insert(identity).inserted else { continue }
                logical = saturatedAdd(logical, UInt64(max(0, info.st_size)))
                allocated = saturatedAdd(allocated, UInt64(max(0, info.st_blocks)) * 512)
            }
        }
        return SDKDirectoryUsage(logicalSize: logical, allocatedSize: allocated)
    }
}
