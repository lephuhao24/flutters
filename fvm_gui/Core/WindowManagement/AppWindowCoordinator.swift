import AppKit
import Observation

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case sdks = "flutterSDKs"
    case projects = "projects"
    case doctor = "flutterDoctor"
    case activity = "activity"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sdks: "Flutter SDKs"
        case .projects: "Projects"
        case .doctor: "Flutter Doctor"
        case .activity: "Activity"
        }
    }
    var symbol: String {
        switch self {
        case .sdks: "externaldrive"
        case .projects: "folder"
        case .doctor: "stethoscope"
        case .activity: "terminal"
        }
    }

    static func restoring(_ storedValue: String?) -> Self? {
        guard let storedValue else { return nil }
        return switch storedValue {
        case "Installed SDKs", "Available Releases", "Storage": .sdks
        default: Self(rawValue: storedValue)
        }
    }
}

@MainActor @Observable final class AppWindowCoordinator {
    static let mainWindowID = "main"

    private static let selectionKey = "app.navigationDestination"
    var selection: AppDestination? {
        didSet {
            if let selection { defaults.set(selection.rawValue, forKey: Self.selectionKey) }
        }
    }
    private(set) var requestedProjectPath: String?
    private(set) var routeRevision = 0
    @ObservationIgnored private var openWindowAction: (@MainActor () -> Void)?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppDestination.restoring(defaults.string(forKey: Self.selectionKey)) ?? .sdks
    }

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
