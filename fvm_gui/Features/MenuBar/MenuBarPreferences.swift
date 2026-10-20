import Foundation
import Observation

@MainActor @Observable final class MenuBarPreferences {
    private let defaults: UserDefaults

    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    var showRecentProjects: Bool { didSet { defaults.set(showRecentProjects, forKey: Key.showRecentProjects) } }
    var keepRunningWhenMainWindowCloses: Bool {
        didSet { defaults.set(keepRunningWhenMainWindowCloses, forKey: Key.keepRunningWhenMainWindowCloses) }
    }
    var recentProjectCount: Int {
        didSet {
            if !Self.allowedRecentProjectCounts.contains(recentProjectCount) {
                recentProjectCount = 5
            } else {
                defaults.set(recentProjectCount, forKey: Key.recentProjectCount)
            }
        }
    }

    static let allowedRecentProjectCounts = [3, 5, 10]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        showRecentProjects = defaults.object(forKey: Key.showRecentProjects) as? Bool ?? true
        keepRunningWhenMainWindowCloses = defaults.object(forKey: Key.keepRunningWhenMainWindowCloses) as? Bool ?? true
        let savedCount = defaults.object(forKey: Key.recentProjectCount) as? Int ?? 5
        recentProjectCount = Self.allowedRecentProjectCounts.contains(savedCount) ? savedCount : 5
    }

    private enum Key {
        static let showMenuBarIcon = "menuBar.showIcon"
        static let showRecentProjects = "menuBar.showRecentProjects"
        static let recentProjectCount = "menuBar.recentProjectCount"
        static let keepRunningWhenMainWindowCloses = "menuBar.keepRunningWhenMainWindowCloses"
    }
}
