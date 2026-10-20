import SwiftUI
import AppKit

@main struct FVMGUIApp: App {
    @NSApplicationDelegateAdaptor(FVMGUIAppDelegate.self) private var appDelegate
    @State private var container = AppContainer()
    var body: some Scene {
        Window("FVM GUI", id: AppWindowCoordinator.mainWindowID) {
            ContentView(container: container, appDelegate: appDelegate)
                .frame(minWidth: 900, minHeight: 560)
                .background {
                    WindowCloseMonitor {
                        if !container.menuBarPreferences.keepRunningWhenMainWindowCloses {
                            NSApp.terminate(nil)
                        }
                    }
                    .frame(width: 0, height: 0)
                }
                .task { if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { await container.start() } }
        }
        .defaultSize(width: 1100, height: 720)
        MenuBarExtra("FVM GUI", systemImage: "shippingbox", isInserted: $container.menuBarPreferences.showMenuBarIcon) {
            FVMMenuBarView(container: container)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(container: container) }
    }
}

@MainActor final class FVMGUIAppDelegate: NSObject, NSApplicationDelegate {
    weak var windowCoordinator: AppWindowCoordinator?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        windowCoordinator?.openMainWindow()
        return true
    }
}
