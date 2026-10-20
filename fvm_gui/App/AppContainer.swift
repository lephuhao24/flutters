import Foundation
import Observation

@MainActor @Observable final class AppContainer {
    let activity: ActivityStore
    var menuBarPreferences: MenuBarPreferences
    var windowCoordinator: AppWindowCoordinator
    let launchAtLogin: any LaunchAtLoginManaging
    let executor: any CLIExecuting
    let locator: any ExecutableLocating
    let setup: DependencySetupViewModel
    let projectService: any ProjectServicing
    let projectDiscovery: ProjectDiscoveryViewModel
    let storageModel: SDKStorageViewModel
    let compatibilityModel: ProjectCompatibilityViewModel
    let projectDashboard: ProjectDashboardViewModel
    let flutterDoctor: FlutterDoctorViewModel
    let projectExport: ProjectExportService
    private let defaults: UserDefaults
    private(set) var installation: FVMInstallation?
    private(set) var sdkModel: SDKViewModel?
    private(set) var releases: [FlutterRelease] = []
    private(set) var projects: [FlutterProject] = []
    private(set) var projectBookmarks: [String: Data] = [:]
    private(set) var recentProjectPaths: [String] = []
    private(set) var approvedScanDirectories: [ApprovedScanDirectory] = []
    private(set) var ignoredProjectPaths = Set<String>()
    private(set) var lastDiscoveryDate: Date?
    private(set) var detecting = false
    private(set) var loadingReleases = false
    private(set) var refreshingProjects = false
    private(set) var preparingProjectDiscovery = false
    private(set) var busy = false
    var error: String?
    var notice: String?
    var manualPath: String
    var manualBrewPath: String
    private var launchChecked = false
    var releaseError: String?
    private var service: (any FVMService)?
    let operation = LongRunningOperation()

    init(defaults: UserDefaults = .standard, executor: any CLIExecuting = CLIExecutor(), locator: (any ExecutableLocating)? = nil, projectService: any ProjectServicing = ProjectService(), setupService: (any DependencySettingUp)? = nil, discoveryService: any ProjectDiscovering = ProjectDiscoveryService(), storageService: any SDKStorageServicing = SDKStorageService(), launchAtLoginService: (any LaunchAtLoginManaging)? = nil) {
        self.defaults = defaults
        self.menuBarPreferences = MenuBarPreferences(defaults: defaults)
        self.windowCoordinator = AppWindowCoordinator()
        self.launchAtLogin = launchAtLoginService ?? LaunchAtLoginService()
        let activity = ActivityStore()
        self.activity = activity
        let loggedExecutor = LoggingCLIExecutor(base: executor, activity: activity)
        self.executor = loggedExecutor
        let fvmLocator = locator ?? ExecutableLocator(executor: loggedExecutor)
        self.locator = fvmLocator
        self.setup = DependencySetupViewModel(service: setupService ?? DependencySetupService(fvmLocator: fvmLocator, brewLocator: HomebrewLocator(executor: loggedExecutor), executor: loggedExecutor), activity: activity)
        self.projectService = projectService
        self.projectDiscovery = ProjectDiscoveryViewModel(service: discoveryService)
        self.storageModel = SDKStorageViewModel(service: storageService)
        self.compatibilityModel = ProjectCompatibilityViewModel(service: ProjectCompatibilityService(
            metadataService: FlutterSDKMetadataService(executor: loggedExecutor),
            constraintEvaluator: PubConstraintEvaluator(executor: loggedExecutor)))
        self.projectDashboard = ProjectDashboardViewModel(actions: ProjectQuickActionService(), activity: activity)
        self.flutterDoctor = FlutterDoctorViewModel(service: FlutterDoctorService(), activity: activity)
        self.projectExport = ProjectExportService()
        manualPath = defaults.string(forKey: "fvmExecutable") ?? ""
        manualBrewPath = defaults.string(forKey: "brewExecutable") ?? ""
        recentProjectPaths = defaults.stringArray(forKey: "recentProjectPaths") ?? []
        if let data = defaults.data(forKey: "projects") {
            do { projects = Self.unique(try JSONDecoder().decode([FlutterProject].self, from: data)) }
            catch { self.error = "Saved project metadata could not be read: \(error.localizedDescription)" }
        }
        if let data = defaults.data(forKey: "projectSecurityBookmarks") {
            projectBookmarks = (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
        }
        if let data = defaults.data(forKey: "projectScanDirectories") {
            approvedScanDirectories = (try? JSONDecoder().decode([ApprovedScanDirectory].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: "ignoredProjects") {
            ignoredProjectPaths = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        }
        lastDiscoveryDate = defaults.object(forKey: "lastProjectDiscovery") as? Date
    }
    func start() async {
        guard !launchChecked else { return }
        launchChecked = true
        await detect()
    }
    func detect() async {
        guard !busy, !detecting, !setup.isWorking else { return }
        detecting = true
        defer { detecting = false }
        manualPath = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        manualBrewPath = manualBrewPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = await setup.check(fvmPath: manualPath, brewPath: manualBrewPath)
        defaults.set(manualBrewPath, forKey: "brewExecutable")
        if let found { await activate(found) }
        else {
            installation = nil; service = nil; sdkModel = nil
            await projectDashboard.configure(fvm: nil)
            await flutterDoctor.configure(fvm: nil)
        }
    }
    func installFVM() async {
        guard !busy, !detecting, !setup.isWorking else { return }
        detecting = true
        defer { detecting = false }
        if let found = await setup.install(fvmPath: manualPath, brewPath: manualBrewPath) { await activate(found) }
    }
    private func activate(_ found: FVMInstallation) async {
        let service = FVMCLIService(installation: found, executor: executor)
        self.service = service
        await projectDashboard.configure(fvm: service)
        await flutterDoctor.configure(fvm: service)
        installation = found
        sdkModel = SDKViewModel(service: service)
        defaults.set(manualPath, forKey: "fvmExecutable")
        error = nil
        releases = []
        releaseError = nil
        await sdkModel?.refresh()
        await refreshProjects()
        await refreshStorage()
    }
    func loadReleases() async {
        guard let service, !loadingReleases else { return }
        loadingReleases = true
        defer { loadingReleases = false }
        do { releases = try await service.releases(); releaseError = nil }
        catch { releaseError = error.localizedDescription }
    }
    func addProject(_ url: URL) async {
        guard let service else { error = "Configure FVM in Settings first."; return }
        do {
            let project = try await projectService.inspect(url, fvm: service)
            if !projects.contains(where: { Self.canonicalPath($0.path) == Self.canonicalPath(project.path) }) {
                projects.append(project)
                if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    projectBookmarks[Self.canonicalPath(project.path)] = bookmark
                    persistProjectBookmarks()
                }
                recordRecentProject(project)
                persist()
                await refreshCompatibility()
            }
        } catch { self.error = error.localizedDescription }
    }
    func refreshProjects() async {
        guard let service, !refreshingProjects else { return }
        refreshingProjects = true
        defer { refreshingProjects = false }
        for original in projects {
            do {
                let project = try await projectService.inspect(URL(fileURLWithPath: original.path), fvm: service)
                if let index = projects.firstIndex(where: { $0.id == original.id }) { projects[index] = project }
            } catch {
                if let index = projects.firstIndex(where: { $0.id == original.id }) { projects[index].issue = error.localizedDescription }
            }
        }
        persist()
        await refreshCompatibility()
    }
    func removeProject(_ project: FlutterProject) {
        let path = Self.canonicalPath(project.path)
        projects.removeAll { Self.canonicalPath($0.path) == path }
        projectBookmarks.removeValue(forKey: path)
        persistProjectBookmarks()
        recentProjectPaths.removeAll { Self.canonicalPath($0) == path }
        defaults.set(recentProjectPaths, forKey: "recentProjectPaths")
        persist()
        Task { await refreshCompatibility() }
    }

    func recordRecentProject(_ project: FlutterProject) {
        let path = Self.canonicalPath(project.path)
        recentProjectPaths.removeAll { Self.canonicalPath($0) == path }
        recentProjectPaths.insert(path, at: 0)
        recentProjectPaths = Array(recentProjectPaths.prefix(100))
        defaults.set(recentProjectPaths, forKey: "recentProjectPaths")
    }

    func recentProjects(limit: Int) -> [FlutterProject] {
        guard limit > 0 else { return [] }
        let byPath = Dictionary(projects.map { (Self.canonicalPath($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let orderedPaths = recentProjectPaths + projects.map { Self.canonicalPath($0.path) }
        return orderedPaths.compactMap { path in
            let canonical = Self.canonicalPath(path)
            guard seen.insert(canonical).inserted else { return nil }
            return byPath[canonical]
        }.prefix(limit).map { $0 }
    }

    func setGlobalSDK(_ name: String) {
        guard !busy, !detecting, !setup.isWorking else { return }
        guard let sdk = sdkModel?.sdks.first(where: { $0.name == name }) else {
            error = "Flutter SDK \(name) is no longer installed. Refresh the SDK list and try again."
            return
        }
        guard !sdk.isGlobal else { return }
        modify(["global", sdk.name])
    }

    func refreshSDKInformation() async {
        guard !busy, !detecting, !setup.isWorking else { return }
        await sdkModel?.refresh()
        await refreshCompatibility()
        await refreshStorage(force: false)
    }

    func approveScanDirectories(_ urls: [URL]) {
        var records = approvedScanDirectories
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !records.contains(where: { Self.canonicalPath($0.path) == canonical.path }) else { continue }
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                records.append(ApprovedScanDirectory(url: canonical, bookmark: bookmark))
            } catch {
                // Directly distributed non-sandbox builds can still scan the selected path.
                records.append(ApprovedScanDirectory(url: canonical))
            }
        }
        approvedScanDirectories = records
        do { defaults.set(try JSONEncoder().encode(records), forKey: "projectScanDirectories") }
        catch { self.error = "Cannot save approved scan directories: \(error.localizedDescription)" }
    }

    func removeScanDirectory(_ record: ApprovedScanDirectory) {
        approvedScanDirectories.removeAll { $0.id == record.id }
        if let data = try? JSONEncoder().encode(approvedScanDirectories) { defaults.set(data, forKey: "projectScanDirectories") }
    }

    func discoverProjects(maximumDepth: Int = 8) {
        guard !approvedScanDirectories.isEmpty, projectDiscovery.status != .running, !preparingProjectDiscovery else { return }
        preparingProjectDiscovery = true
        let access = ScanDirectoryAccess()
        let records = approvedScanDirectories
        Task { @MainActor [weak self] in
            guard let self else { return }
            let roots = await access.acquire(records)
            projectDiscovery.scan(roots: roots, maximumDepth: maximumDepth, ignoredPaths: ignoredProjectPaths) { [weak self] date in
                guard let self, let date else { return }
                lastDiscoveryDate = date
                defaults.set(date, forKey: "lastProjectDiscovery")
            }
            await projectDiscovery.wait()
            await access.release()
            preparingProjectDiscovery = false
            await refreshCompatibility()
        }
    }

    func importDiscoveredProjects(_ projectsToImport: [FlutterProject]) {
        var existing = Set(projects.map { Self.canonicalPath($0.path) })
        for project in projectsToImport {
            let path = Self.canonicalPath(project.path)
            guard existing.insert(path).inserted, !ignoredProjectPaths.contains(path) else { continue }
            projects.append(project)
            recordRecentProject(project)
        }
        persist()
        Task { await refreshCompatibility() }
    }

    func ignoreDiscoveredProject(_ project: FlutterProject) {
        let path = Self.canonicalPath(project.path)
        ignoredProjectPaths.insert(path)
        defaults.set(try? JSONEncoder().encode(ignoredProjectPaths), forKey: "ignoredProjects")
        projectDiscovery.remove(project)
        Task { await refreshCompatibility() }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func unique(_ projects: [FlutterProject]) -> [FlutterProject] {
        var seen = Set<String>()
        return projects.filter { seen.insert(canonicalPath($0.path)).inserted }
    }
    private func persist() {
        do { defaults.set(try JSONEncoder().encode(Self.unique(projects)), forKey: "projects") }
        catch { self.error = "Cannot save projects: \(error.localizedDescription)" }
    }

    private func persistProjectBookmarks() {
        do { defaults.set(try JSONEncoder().encode(projectBookmarks), forKey: "projectSecurityBookmarks") }
        catch { self.error = "Cannot save project access bookmarks: \(error.localizedDescription)" }
    }

    func refreshCompatibility(force: Bool = false) async {
        await compatibilityModel.refresh(projects: projects, sdks: sdkModel?.sdks ?? [], force: force)
    }
    func modify(_ arguments: [String], directory: URL? = nil) {
        guard !busy, !detecting, !setup.isWorking, let service else { return }
        busy = true
        notice = nil
        let id = activity.begin(command: "fvm " + arguments.map { $0.contains(" ") ? String(reflecting: $0) : $0 }.joined(separator: " ") + (directory.map { "\nDirectory: \($0.path)" } ?? ""))
        operation.start { [self] progress in
            defer { busy = false }
            var failure: (any Error)?
            await progress(OperationProgress(message: "Running FVM…"))
            do {
                try Task.checkCancellation()
                try await service.modify(arguments, directory: directory) { [activity] event in
                    await activity.append((event.isError ? "[stderr] " : "") + event.text, id: id)
                }
                activity.finish(id, status: .completed)
                notice = "Operation completed."
            } catch is CancellationError {
                failure = CancellationError()
                activity.finish(id, status: .cancelled)
                notice = "Operation cancelled. Partial downloads may remain; refresh before retrying."
            } catch {
                failure = error
                activity.append(error.localizedDescription, id: id)
                activity.finish(id, status: .failed)
                self.error = error.localizedDescription
            }
            // Unstructured task intentionally does not inherit cancellation.
            let refresh = Task {
                await sdkModel?.refresh()
                await refreshProjects()
                await refreshStorage(force: true)
            }
            await refresh.value
            if let failure { throw failure }
        }
    }
    func cancel() { operation.cancel() }

    func refreshStorage(force: Bool = false) async {
        if force { await sdkModel?.refresh() }
        storageModel.refresh(sdks: sdkModel?.sdks ?? [], registeredProjects: projects,
                             discoveredProjects: projectDiscovery.projects, force: force)
        await storageModel.wait()
    }

    func sdkRemovalBlockReason(version: String) -> String? {
        let sdk = sdkModel?.sdks.first(where: { $0.name == version })
        return SDKRemovalPolicy.blockReason(sdk: sdk,
                                             operationActive: busy || detecting || setup.isWorking || operation.status == .running)
    }

    func sdkReferenceWarning(version: String) -> String? {
        guard let sdk = sdkModel?.sdks.first(where: { $0.name == version }) else { return nil }
        let registered = projects.filter { Self.references($0, sdk: sdk) }
        let registeredPaths = Set(registered.map { Self.canonicalPath($0.path) })
        let discovered = projectDiscovery.projects.filter {
            !registeredPaths.contains(Self.canonicalPath($0.path)) && Self.references($0, sdk: sdk)
        }
        return SDKRemovalPolicy.referenceWarning(sdk: sdk, registeredReferences: registered.count, discoveredReferences: discovered.count)
    }

    func removeSDKFromStorage(version: String) {
        guard let reason = sdkRemovalBlockReason(version: version) else {
            modify(["remove", version])
            return
        }
        error = reason
    }

    private static func references(_ project: FlutterProject, sdk: FlutterSDK?) -> Bool {
        guard project.type != .dartPackage, let sdk else { return false }
        let version = project.configuredVersion ?? project.version
        return version == sdk.name || version == sdk.flutterSdkVersion
    }
}
