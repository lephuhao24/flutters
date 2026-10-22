import Darwin
import Dispatch
import Foundation
import Observation

@MainActor @Observable final class ProjectCompatibilityViewModel {
    private(set) var results: [String: [String: ProjectCompatibility]] = [:]
    private(set) var isRefreshing = false
    private(set) var progress: OperationProgress?
    private(set) var error: String?
    private let service: any ProjectCompatibilityServicing
    private var projects: [FlutterProject] = []
    private var sdks: [FlutterSDK] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watchedPaths = Set<String>()

    init(service: any ProjectCompatibilityServicing) { self.service = service }

    func result(for project: FlutterProject, sdkVersion: String? = nil) -> ProjectCompatibility? {
        let version = sdkVersion ?? project.effectiveVersion ?? sdks.first(where: \.isGlobal)?.name
        guard let version else { return results[project.id]?.values.first }
        if let result = results[project.id]?[version] { return result }
        if let sdk = sdks.first(where: { $0.name == version || $0.flutterSdkVersion == version }) {
            return results[project.id]?[sdk.name]
        }
        return nil
    }

    func refresh(projects: [FlutterProject], sdks: [FlutterSDK], force: Bool = false) async {
        self.projects = projects
        self.sdks = sdks
        monitorFiles(projects: projects, sdks: sdks)
        guard !isRefreshing else { return }
        isRefreshing = true
        error = nil
        progress = OperationProgress(message: "Checking project SDK compatibility…")
        defer { isRefreshing = false; progress = nil }
        do {
            for (index, project) in projects.enumerated() {
                try Task.checkCancellation()
                let version = project.effectiveVersion ?? sdks.first(where: \.isGlobal)?.name
                let sdk = sdks.first { $0.name == version || $0.flutterSdkVersion == version }
                let result = await service.evaluate(project: project, sdk: sdk, installedSDKs: sdks, forceRefresh: force)
                results[project.id, default: [:]][sdk?.name ?? "<missing>"] = result
                progress = OperationProgress(message: "Checked \(index + 1) of \(projects.count) projects")
            }
            monitorFiles(projects: projects, sdks: sdks)
        } catch is CancellationError {
            progress = OperationProgress(message: "Compatibility check cancelled.")
        } catch { self.error = error.localizedDescription }
    }

    func check(project: FlutterProject, sdkVersion: String) async -> ProjectCompatibility? {
        guard let sdk = sdks.first(where: { $0.name == sdkVersion || $0.flutterSdkVersion == sdkVersion }) else {
            let missing = await service.evaluate(project: project, sdk: nil, installedSDKs: sdks, forceRefresh: false)
            results[project.id, default: [:]][sdkVersion] = missing
            return missing
        }
        let result = await service.evaluate(project: project, sdk: sdk, installedSDKs: sdks, forceRefresh: false)
        results[project.id, default: [:]][sdk.name] = result
        return result
    }

    func compatibleSuggestions(for project: FlutterProject, excluding version: String) async -> [String] {
        var compatible: [String] = []
        for sdk in sdks where sdk.name != version {
            if let result = await check(project: project, sdkVersion: sdk.name), result.status == .compatible {
                compatible.append(sdk.name)
            }
        }
        return compatible
    }

    private func monitorFiles(projects: [FlutterProject], sdks: [FlutterSDK]) {
        var paths = Set<String>()
        for project in projects {
            paths.insert(URL(fileURLWithPath: project.path, isDirectory: true).path)
            if let source = project.configurationSource {
                paths.insert(URL(fileURLWithPath: source).deletingLastPathComponent().path)
            }
        }
        for result in results.values.flatMap(\.values) {
            if let source = result.configurationSource {
                paths.insert(URL(fileURLWithPath: source).deletingLastPathComponent().path)
            }
        }
        for sdk in sdks {
            let root = URL(fileURLWithPath: sdk.directory, isDirectory: true)
            paths.insert(root.path)
            paths.insert(root.appendingPathComponent("bin/cache/dart-sdk", isDirectory: true).path)
        }
        guard paths != watchedPaths else { return }
        watchers.forEach { $0.cancel() }
        watchers = []
        watchedPaths = paths
        for path in paths {
            guard let watcher = Self.makeWatcher(at: path, onChange: { [weak self] in
                guard let self else { return }
                await self.refresh(projects: self.projects, sdks: self.sdks, force: true)
            }) else { continue }
            watchers.append(watcher)
        }
    }

    /// Creates and owns the DispatchSource outside the MainActor. Dispatch invokes
    /// its cancel handler on the source's queue, so inheriting MainActor isolation
    /// here would trap when the descriptor is closed during watcher replacement.
    private nonisolated static func makeWatcher(
        at path: String,
        onChange: @escaping @MainActor @Sendable () async -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        watcher.setEventHandler {
            Task { @MainActor in await onChange() }
        }
        watcher.setCancelHandler { _ = Darwin.close(descriptor) }
        watcher.resume()
        return watcher
    }
}
