import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var container: AppContainer
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dependency Settings").font(.title2)
                menuBarSettings
                launchAtLoginSettings
                if let installation = container.installation {
                    LabeledContent("FVM Version", value: installation.version)
                    Text(installation.executable.path).font(.caption).textSelection(.enabled)
                }
                ExecutablePathsView(container: container)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project IDE Preferences").font(.headline)
                    Text("Choose applications for project quick actions. Launch Services is used to find installed IDEs, including apps outside /Applications.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(ProjectIDE.allCases) { ide in
                        HStack {
                            Label(ide.title, systemImage: ide == .xcode ? "hammer" : "app")
                            Spacer()
                            Text(container.projectDashboard.ideOpening.preferences.path(for: ide)
                                 ?? (container.projectDashboard.ideOpening.isAvailable(ide) ? "Detected" : "Not found"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { container.projectDashboard.ideOpening.chooseApplication(for: ide) }
                            if container.projectDashboard.ideOpening.preferences.path(for: ide) != nil {
                                Button("Reset") { container.projectDashboard.ideOpening.preferences.setApplication(nil, for: ide) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                Label(container.setup.state.rawValue, systemImage: container.setup.state == .ready ? "checkmark.circle" : "info.circle")
                if container.setup.isWorking { ProgressView().controlSize(.small) }
                if let detail = container.setup.detail { Text(detail).foregroundStyle(.secondary).textSelection(.enabled) }
                if container.setup.state != .ready { Text("Dependency setup and installation output are available in the main window.").font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
        }.frame(width: 620, height: 720)
    }

    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu Bar Companion").font(.headline)
            Toggle("Show Menu Bar Icon", isOn: $container.menuBarPreferences.showMenuBarIcon)
            Toggle("Show Recent Projects", isOn: $container.menuBarPreferences.showRecentProjects)
            Picker("Number of Recent Projects", selection: $container.menuBarPreferences.recentProjectCount) {
                ForEach(MenuBarPreferences.allowedRecentProjectCounts, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .disabled(!container.menuBarPreferences.showRecentProjects)
            Toggle("Keep Running When Main Window Closes", isOn: $container.menuBarPreferences.keepRunningWhenMainWindowCloses)
            Text("FVM GUI remains a regular Dock app. Hiding the menu bar icon does not remove access from the Dock.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var launchAtLoginSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launch at Login").font(.headline)
            Toggle("Open FVM GUI when you log in", isOn: Binding(
                get: { container.launchAtLogin.status == .enabled || container.launchAtLogin.status == .requiresApproval },
                set: { enabled in
                    do { try container.launchAtLogin.setEnabled(enabled) }
                    catch { container.error = "Launch at Login could not be updated: \(error.localizedDescription)" }
                }
            ))
            .disabled(container.launchAtLogin.status == .unavailable)
            LabeledContent("Registration Status", value: container.launchAtLogin.status.title)
                .font(.caption)
            if container.launchAtLogin.status == .requiresApproval {
                Label("macOS requires approval in System Settings > General > Login Items.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            if let error = container.launchAtLogin.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
