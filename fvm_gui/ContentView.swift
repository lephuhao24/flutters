import SwiftUI

struct ContentView: View {
    @Bindable var container: AppContainer
    let appDelegate: FVMGUIAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(AppDestination.allCases, selection: $container.windowCoordinator.selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("FVM GUI")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            VStack(alignment: .leading, spacing: 8) {
                if container.busy { ProgressView().controlSize(.small); Text("SDK operation running").font(.caption) }
                Text(container.installation.map { "FVM \($0.version)" } ?? "FVM unavailable").font(.caption).foregroundStyle(.secondary)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }.padding()
        } detail: {
            VStack(spacing: 0) {
                if let notice = container.notice {
                    HStack { Label(notice, systemImage: "info.circle"); Spacer(); Button("Dismiss") { container.notice = nil } }
                        .font(.callout).padding().background(.quaternary)
                }
                if container.setup.state != .ready {
                    DependencySetupView(container: container)
                } else if container.detecting {
                    ProgressView("Loading FVM…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch container.windowCoordinator.selection ?? .sdks {
                    case .sdks: SDKsView(container: container)
                    case .projects: ProjectsView(container: container) { project in
                        container.flutterDoctor.runProject(project, installedSDKs: container.sdkModel?.sdks ?? [])
                        container.windowCoordinator.selection = .doctor
                    }
                    case .doctor: FlutterDoctorView(container: container)
                    case .activity: ActivityView(container: container)
                    }
                }
            }.navigationTitle((container.windowCoordinator.selection ?? .sdks).title)
        }
        .onAppear {
            appDelegate.windowCoordinator = container.windowCoordinator
            container.windowCoordinator.registerOpenWindowAction { openWindow(id: AppWindowCoordinator.mainWindowID) }
        }
        .alert("Operation Failed", isPresented: Binding(get: { container.error != nil }, set: { if !$0 { container.error = nil } })) {
            Button("OK") { container.error = nil }
        } message: { Text(container.error ?? "") }
    }
}
