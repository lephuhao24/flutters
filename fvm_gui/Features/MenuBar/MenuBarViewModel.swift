import Foundation
import Observation
import AppKit

@MainActor @Observable final class MenuBarViewModel {
    private let container: AppContainer
    private(set) var refreshing = false
    private(set) var missingProjectPaths = Set<String>()

    init(container: AppContainer) { self.container = container }

    var recentProjects: [FlutterProject] {
        guard container.menuBarPreferences.showRecentProjects else { return [] }
        return container.recentProjects(limit: container.menuBarPreferences.recentProjectCount)
    }

    var globalSDK: FlutterSDK? { container.sdkModel?.sdks.first(where: \.isGlobal) }
    var installedSDKs: [FlutterSDK] { container.sdkModel?.sdks ?? [] }

    func refreshIfStale() async {
        let staleAfter: TimeInterval = 60
        if let lastRefresh = container.sdkModel?.lastRefreshDate,
           Date().timeIntervalSince(lastRefresh) < staleAfter { return }
        await refresh()
    }

    func refreshProjectAvailability() async {
        let paths = recentProjects.map(\.path)
        let missing = await Task.detached(priority: .utility) {
            Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        }.value
        guard !Task.isCancelled else { return }
        missingProjectPaths = missing
    }

    func refresh() async {
        guard !refreshing, !container.busy else { return }
        refreshing = true
        defer { refreshing = false }
        await container.refreshSDKInformation()
    }

    func setGlobalSDK(_ sdk: FlutterSDK) {
        container.setGlobalSDK(sdk.name)
    }

    func openPreferredIDE(for project: FlutterProject) {
        container.recordRecentProject(project)
        Task { await container.projectDashboard.open(container.projectDashboard.ideOpening.preferences.preferredIDE, for: project) }
    }

    func openInFinder(_ project: FlutterProject) {
        guard !isMissing(project), FileManager.default.fileExists(atPath: project.path) else {
            container.error = "The project directory no longer exists at \(project.path). Refresh the Projects list."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func openDashboard(for project: FlutterProject) {
        guard !isMissing(project), FileManager.default.fileExists(atPath: project.path) else {
            container.error = "The project directory no longer exists at \(project.path). Refresh the Projects list."
            return
        }
        container.recordRecentProject(project)
        container.windowCoordinator.openProjectDashboard(path: project.path)
    }

    func isMissing(_ project: FlutterProject) -> Bool {
        if missingProjectPaths.contains(URL(fileURLWithPath: project.path).standardizedFileURL.path) { return true }
        guard let issue = project.issue?.lowercased() else { return false }
        return issue.contains("folder is missing") || issue.contains("does not exist")
    }
}
