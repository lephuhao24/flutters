import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum ProjectIDE: String, CaseIterable, Identifiable, Sendable {
    case finder, terminal, visualStudioCode, androidStudio, xcode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .finder: "Finder"
        case .terminal: "Terminal"
        case .visualStudioCode: "Visual Studio Code"
        case .androidStudio: "Android Studio"
        case .xcode: "Xcode"
        }
    }
    var bundleIdentifiers: [String] {
        switch self {
        case .finder: ["com.apple.finder"]
        case .terminal: ["com.apple.Terminal"]
        case .visualStudioCode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .androidStudio: ["com.google.android.studio"]
        case .xcode: ["com.apple.dt.Xcode"]
        }
    }
}

enum ProjectIDEOpeningError: LocalizedError, Sendable {
    case applicationUnavailable(String)
    case workspaceUnavailable
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .applicationUnavailable(let name): "\(name) is not installed or available. Configure its application in Settings."
        case .workspaceUnavailable: "No iOS .xcworkspace was found in this project. Open the iOS folder in Xcode manually if needed."
        case .failed(let message): "Could not open the project: \(message)"
        }
    }
}

@MainActor protocol IDEApplicationResolving {
    func applicationURL(for ide: ProjectIDE, preferredPath: String?) -> URL?
    func open(_ urls: [URL], with applicationURL: URL) async throws
}

@MainActor struct LaunchServicesIDEApplicationResolver: IDEApplicationResolving {
    func applicationURL(for ide: ProjectIDE, preferredPath: String?) -> URL? {
        if let preferredPath, FileManager.default.fileExists(atPath: preferredPath) {
            return URL(fileURLWithPath: preferredPath)
        }
        for identifier in ide.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        // Launch Services also knows applications registered outside /Applications,
        // including user Applications folders and custom install locations.
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: "/"))
            .first { url in
                guard let identifier = Bundle(url: url)?.bundleIdentifier else { return false }
                return ide.bundleIdentifiers.contains(identifier)
            }
    }

    func open(_ urls: [URL], with applicationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: applicationURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: ProjectIDEOpeningError.failed(error.localizedDescription)) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

@MainActor @Observable final class ProjectIDEPreferences {
    private let defaults: UserDefaults
    private(set) var applicationPaths: [ProjectIDE: String] = [:]
    private(set) var preferredIDE: ProjectIDE

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredIDE = defaults.string(forKey: "projectIDE.preferred")
            .flatMap(ProjectIDE.init(rawValue:)) ?? .visualStudioCode
        for ide in ProjectIDE.allCases {
            if let path = defaults.string(forKey: Self.key(ide)) { applicationPaths[ide] = path }
        }
    }

    func path(for ide: ProjectIDE) -> String? { applicationPaths[ide] }
    func setApplication(_ url: URL?, for ide: ProjectIDE) {
        if let url {
            applicationPaths[ide] = url.path
            defaults.set(url.path, forKey: Self.key(ide))
        } else {
            applicationPaths.removeValue(forKey: ide)
            defaults.removeObject(forKey: Self.key(ide))
        }
    }

    func setPreferredIDE(_ ide: ProjectIDE) {
        guard ide != .finder else { return }
        preferredIDE = ide
        defaults.set(ide.rawValue, forKey: "projectIDE.preferred")
    }

    private static func key(_ ide: ProjectIDE) -> String { "projectIDE.\(ide.rawValue).applicationPath" }
}

@MainActor final class ProjectIDEOpeningService {
    let preferences: ProjectIDEPreferences
    private let resolver: any IDEApplicationResolving

    init(preferences: ProjectIDEPreferences = ProjectIDEPreferences(),
         resolver: any IDEApplicationResolving = LaunchServicesIDEApplicationResolver()) {
        self.preferences = preferences
        self.resolver = resolver
    }

    func isAvailable(_ ide: ProjectIDE) -> Bool {
        resolver.applicationURL(for: ide, preferredPath: preferences.path(for: ide)) != nil
    }

    func open(_ ide: ProjectIDE, project: FlutterProject) async throws {
        let projectURL = URL(fileURLWithPath: project.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw ProjectIDEOpeningError.failed("The project directory no longer exists at \(project.path). Refresh the Projects list.")
        }
        switch ide {
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([projectURL])
        case .terminal, .visualStudioCode, .androidStudio:
            try await openURLs([projectURL], with: ide)
        case .xcode:
            guard let workspace = Self.iOSWorkspace(in: projectURL) else { throw ProjectIDEOpeningError.workspaceUnavailable }
            try await openURLs([workspace], with: ide)
        }
    }

    func chooseApplication(for ide: ProjectIDE) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Application"
        if let path = preferences.path(for: ide) { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        panel.begin { [weak preferences] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in preferences?.setApplication(url, for: ide) }
        }
    }

    static func iOSWorkspace(in projectURL: URL, fileManager: FileManager = .default) -> URL? {
        let iosURL = projectURL.appendingPathComponent("ios", isDirectory: true)
        let roots = [iosURL, projectURL]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            let workspaces = contents.filter { $0.pathExtension == "xcworkspace" }
            if let runner = workspaces.first(where: { $0.lastPathComponent == "Runner.xcworkspace" }) { return runner }
            if let first = workspaces.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first { return first }
        }
        return nil
    }

    private func openURLs(_ urls: [URL], with ide: ProjectIDE) async throws {
        guard let application = resolver.applicationURL(for: ide, preferredPath: preferences.path(for: ide)) else {
            throw ProjectIDEOpeningError.applicationUnavailable(ide.title)
        }
        try await resolver.open(urls, with: application)
    }
}
