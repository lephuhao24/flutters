import AppKit
import SwiftUI

struct FVMMenuBarView: View {
    @Bindable var container: AppContainer
    @State private var model: MenuBarViewModel

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: MenuBarViewModel(container: container))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            globalSDKSection
            if container.menuBarPreferences.showRecentProjects {
                Divider()
                recentProjectsSection
            }
            Divider()
            quickActions
            if let message = container.error ?? container.projectDashboard.error {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
        .task {
            await model.refreshProjectAvailability()
            await model.refreshIfStale()
        }
        .task(id: model.recentProjects.map(\.path).joined(separator: "|")) {
            await model.refreshProjectAvailability()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.title2).symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("FVM GUI").font(.headline)
                Text(container.installation.map { "FVM \($0.version)" } ?? "FVM CLI unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Open Settings")
                .accessibilityLabel("Open Settings")
        }
    }

    private var globalSDKSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GLOBAL FLUTTER SDK")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if container.busy || model.refreshing || (container.sdkModel?.loading ?? false) {
                    ProgressView().controlSize(.small)
                }
            }
            if let sdk = model.globalSDK {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(sdk.flutterSdkVersion ?? sdk.name).font(.title3.weight(.semibold))
                    if let channel = sdk.channel {
                        Text(channel.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Label(sdk.isSetup ? "Installed and ready" : "Setup required", systemImage: sdk.isSetup ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(sdk.isSetup ? Color.secondary : Color.orange)
                Menu {
                    ForEach(model.installedSDKs) { option in
                        Button {
                            model.setGlobalSDK(option)
                        } label: {
                            if option.isGlobal {
                                Label("\(option.name) · Current", systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                        .disabled(container.busy || option.isGlobal)
                    }
                } label: {
                    Label("Change Global SDK…", systemImage: "arrow.triangle.swap")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .disabled(container.busy || model.installedSDKs.isEmpty)
            } else {
                ContentUnavailableView("No Global SDK", systemImage: "exclamationmark.circle", description: Text(model.installedSDKs.isEmpty ? "Install a Flutter SDK in FVM GUI first." : "Choose an installed SDK to set it as global."))
                    .frame(maxWidth: .infinity, minHeight: 62)
                if !model.installedSDKs.isEmpty {
                    Menu("Set Global SDK…") {
                        ForEach(model.installedSDKs) { sdk in
                            Button(sdk.name) { model.setGlobalSDK(sdk) }.disabled(container.busy)
                        }
                    }
                }
            }
            if container.sdkModel?.error != nil {
                Text(container.sdkModel?.error ?? "").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT PROJECTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    container.windowCoordinator.selection = .projects
                    container.windowCoordinator.openMainWindow()
                } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open Projects")
                    .accessibilityLabel("Open Projects")
            }
            if model.recentProjects.isEmpty {
                Text("Projects you open will appear here.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ForEach(model.recentProjects) { project in recentProjectRow(project) }
            }
        }
    }

    private func recentProjectRow(_ project: FlutterProject) -> some View {
        let missing = model.isMissing(project)
        let version = project.effectiveVersion ?? "No Flutter SDK configured"
        let sdkMissing = project.type != .dartPackage && project.effectiveVersion != nil &&
            !model.installedSDKs.contains { $0.name == project.effectiveVersion || $0.flutterSdkVersion == project.effectiveVersion }

        return HStack(spacing: 8) {
            Button { model.openDashboard(for: project) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(missing)
            if missing {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).help(project.issue ?? "Project directory is missing")
            } else if sdkMissing {
                Label("SDK missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange).help("The configured Flutter SDK is not installed")
            }
            Menu {
                Button("Open Project Dashboard") { model.openDashboard(for: project) }.disabled(missing)
                Button("Open in Preferred IDE · \(container.projectDashboard.ideOpening.preferences.preferredIDE.title)") {
                    model.openPreferredIDE(for: project)
                }.disabled(missing)
                Button("Show in Finder") { model.openInFinder(project) }.disabled(missing)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .disabled(missing)
            .accessibilityLabel("Actions for \(project.name)")
        }
        .padding(.vertical, 2)
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refresh() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.refreshing || container.busy || container.sdkModel == nil)
            Spacer(minLength: 0)
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .labelStyle(.iconOnly).help("Open Settings")
            Button {
                container.windowCoordinator.openMainWindow()
            } label: { Label("Open FVM GUI", systemImage: "macwindow") }
                .help("Open FVM GUI")
            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit FVM GUI")
        }
        .controlSize(.small)
    }
}
