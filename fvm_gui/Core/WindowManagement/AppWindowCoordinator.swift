import AppKit
import Observation

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case sdks = "Installed SDKs"
    case storage = "Storage"
    case releases = "Available Releases"
    case projects = "Projects"
    case doctor = "Flutter Doctor"
    case activity = "Activity"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .sdks: "externaldrive"
        case .storage: "externaldrive.badge.timemachine"
        case .releases: "arrow.down.circle"
        case .projects: "folder"
        case .doctor: "stethoscope"
        case .activity: "terminal"
        }
    }
}

@MainActor @Observable final class AppWindowCoordinator {
    static let mainWindowID = "main"

    var selection: AppDestination? = .sdks
    private(set) var requestedProjectPath: String?
    private(set) var routeRevision = 0
    @ObservationIgnored private var openWindowAction: (@MainActor () -> Void)?

    func registerOpenWindowAction(_ action: @escaping @MainActor () -> Void) {
        openWindowAction = action
    }

    func openMainWindow() {
        openWindowAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openProjectDashboard(path: String) {
        requestedProjectPath = path
        selection = .projects
        routeRevision &+= 1
        openMainWindow()
    }

    func consumeRequestedProjectPath() -> String? {
        defer { requestedProjectPath = nil }
        return requestedProjectPath
    }
}
