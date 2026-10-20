import SwiftUI
import AppKit

struct ProjectsView: View {
    @Bindable var container: AppContainer
    let onRunDoctor: (FlutterProject) -> Void
    @State private var changing: FlutterProject?
    @State private var chosenVersion = ""
    @State private var showingDiscovery = false
    @State private var selectedProjectPath: String?
    private var compatibilitySignature: String {
        (container.projects.map { "\($0.path):\($0.effectiveVersion ?? "")" } +
         (container.sdkModel?.sdks ?? []).map { "\($0.name):\($0.directory):\($0.flutterSdkVersion ?? "")" }).joined(separator: "|")
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Projects").font(.headline)
                    Spacer()
                    Button { addProject() } label: { Image(systemName: "folder.badge.plus") }.help("Add Project")
                }.padding(.horizontal, 12).padding(.vertical, 10)
                if container.projects.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "folder", description: Text("Add a project or discover projects in selected folders."))
                } else {
                    List(selection: $selectedProjectPath) {
                        ForEach(container.projects) { project in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(project.name, systemImage: project.type == .dartPackage ? "shippingbox" : "folder")
                                    .font(.headline).lineLimit(1)
                                HStack {
                                    Text(project.effectiveVersion ?? "No Flutter SDK").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    compatibilityStatus(project)
                                }
                            }
                            .padding(.vertical, 5)
                            .tag(project.path)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                                Button("Change Flutter SDK…") { changeVersion(project) }
                                Divider()
                                Button("Remove from List", role: .destructive) { container.removeProject(project) }
                            }
                        }
                    }.listStyle(.sidebar)
                }
            }
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 310)
            Divider()
            if let project = selectedProject {
                ProjectDashboardView(container: container, project: project,
                                     onChangeSDK: { changeVersion(project) },
                                     onRunDoctor: { onRunDoctor(project) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Project", systemImage: "rectangle.split.2x1", description: Text("Choose a registered project to view its environment and quick actions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button { Task { await container.refreshProjects() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(container.busy || container.refreshingProjects)
            Button { showingDiscovery = true } label: { Label("Discover Projects", systemImage: "sparkle.magnifyingglass") }
            Button { addProject() } label: { Label("Add Project", systemImage: "folder.badge.plus") }.disabled(container.busy)
        }
        .sheet(isPresented: $showingDiscovery) {
            ProjectDiscoverySheet(container: container, onSelectFolders: selectFolders)
                .frame(minWidth: 760, minHeight: 540)
        }
        .sheet(item: $changing) { project in
            ProjectVersionSelectionSheet(container: container, project: project, chosenVersion: $chosenVersion) { changing = nil }
        }
        .task(id: compatibilitySignature) { await container.refreshCompatibility() }
        .onAppear {
            if let requestedPath = container.windowCoordinator.consumeRequestedProjectPath(),
               container.projects.contains(where: { $0.path == requestedPath }) {
                selectedProjectPath = requestedPath
            } else if selectedProjectPath == nil {
                selectedProjectPath = container.recentProjects(limit: 1).first?.path ?? container.projects.first?.path
            }
        }
        .onChange(of: container.windowCoordinator.routeRevision) { _, _ in
            guard let requestedPath = container.windowCoordinator.consumeRequestedProjectPath(),
                  container.projects.contains(where: { $0.path == requestedPath }) else { return }
            selectedProjectPath = requestedPath
        }
        .onChange(of: selectedProjectPath) { _, path in
            guard let path, let project = container.projects.first(where: { $0.path == path }) else { return }
            container.recordRecentProject(project)
        }
        .onChange(of: container.projects.map(\.path)) { _, paths in
            if !paths.contains(selectedProjectPath ?? "") { selectedProjectPath = paths.first }
        }
    }

    private var selectedProject: FlutterProject? { container.projects.first { $0.path == selectedProjectPath } }

    @ViewBuilder private func compatibilityStatus(_ project: FlutterProject) -> some View {
        if let result = container.compatibilityModel.result(for: project) {
            Label(result.status.title, systemImage: statusSymbol(result.status))
                .font(.caption).foregroundStyle(statusColor(result.status)).help(result.explanation)
        } else {
            Label("Checking compatibility", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statusSymbol(_ status: ProjectCompatibilityStatus) -> String {
        switch status {
        case .compatible: "checkmark.circle.fill"
        case .incompatible: "xmark.octagon.fill"
        case .sdkMissing: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        case .unableToEvaluate: "exclamationmark.circle"
        }
    }

    private func statusColor(_ status: ProjectCompatibilityStatus) -> Color {
        switch status {
        case .compatible: .green
        case .incompatible: .red
        case .sdkMissing, .unableToEvaluate: .orange
        case .unknown: .secondary
        }
    }

    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Discover Projects"
        panel.message = "Choose folders to scan. FVM GUI scans only the folders you select."
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                container.approveScanDirectories(urls)
                container.discoverProjects()
            }
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.begin { response in
            if response == .OK, let url = panel.url { Task { @MainActor in await container.addProject(url) } }
        }
    }

    private func changeVersion(_ project: FlutterProject) {
        chosenVersion = project.effectiveVersion ?? container.sdkModel?.sdks.first?.name ?? ""
        changing = project
    }
}

private struct ProjectVersionSelectionSheet: View {
    @Bindable var container: AppContainer
    let project: FlutterProject
    @Binding var chosenVersion: String
    let onApply: () -> Void
    @State private var compatibility: ProjectCompatibility?
    @State private var compatibleSuggestions: [String] = []
    @State private var checking = false
    @State private var checkingSuggestions = false
    @State private var confirming = false

    private var sdks: [FlutterSDK] { container.sdkModel?.sdks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Flutter Version").font(.title2.weight(.semibold))
            Text(project.name).font(.headline)
            Picker("Flutter SDK", selection: $chosenVersion) {
                ForEach(sdks) { sdk in
                    HStack {
                        Text(sdk.name)
                        if sdk.isGlobal { Text("Global") }
                    }.tag(sdk.name)
                }
            }
            if checking {
                ProgressView("Evaluating with Dart Pub…").controlSize(.small)
            } else if let compatibility {
                compatibilityDetails(compatibility)
            }
            Text("FVM changes this project's SDK configuration only after you apply. An inherited configuration will be overridden locally. Dependency resolution is skipped.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onApply)
                Spacer()
                Button("Apply") { applyOrConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(checking || compatibility == nil || container.busy || !sdks.contains { $0.name == chosenVersion })
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .task(id: chosenVersion) {
            compatibility = nil
            compatibleSuggestions = []
            checking = true
            compatibility = await container.compatibilityModel.check(project: project, sdkVersion: chosenVersion)
            checking = false
            guard compatibility?.status == .incompatible else { return }
            checkingSuggestions = true
            compatibleSuggestions = await container.compatibilityModel.compatibleSuggestions(for: project, excluding: chosenVersion)
            checkingSuggestions = false
        }
        .confirmationDialog("Use an SDK with unverified compatibility?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Use \(chosenVersion) Anyway", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(compatibility?.explanation ?? "Compatibility could not be confirmed.")\n\n\(compatibility?.recommendedAction ?? "Proceed only if you understand the risk.")")
        }
    }

    @ViewBuilder private func compatibilityDetails(_ result: ProjectCompatibility) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(result.status.title, systemImage: symbol(result.status))
                .font(.headline).foregroundStyle(color(result.status))
            HStack(spacing: 12) {
                Text("SDK \(result.selectedFlutterSDK ?? "unknown") · Flutter \(result.selectedFlutterVersion ?? "unknown")")
                Text("Dart \(result.bundledDartSDKVersion ?? "unknown")")
            }.font(.caption).foregroundStyle(.secondary)
            if let configured = result.configuredFlutterVersion {
                Text("Configured: \(configured) · Effective: \(result.effectiveFlutterVersion ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let dart = result.requiredDartConstraint { Text("Dart requirement: \(dart)").font(.caption) }
            if let flutter = result.requiredFlutterConstraint { Text("Flutter requirement: \(flutter)").font(.caption) }
            Text(result.explanation).font(.callout).textSelection(.enabled)
            if result.status == .incompatible {
                if checkingSuggestions {
                    ProgressView("Checking other installed SDKs…").controlSize(.small)
                } else if compatibleSuggestions.isEmpty {
                    Text("No compatible installed SDK was found.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Compatible installed SDKs: \(compatibleSuggestions.joined(separator: ", "))")
                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                }
            }
            Text(result.recommendedAction).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color(result.status).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func applyOrConfirm() {
        if compatibility?.status == .compatible { apply() }
        else { confirming = true }
    }

    private func apply() {
        container.modify(["use", chosenVersion, "--skip-pub-get"], directory: URL(fileURLWithPath: project.path))
        onApply()
    }

    private func symbol(_ status: ProjectCompatibilityStatus) -> String {
        switch status {
        case .compatible: "checkmark.circle.fill"
        case .incompatible: "xmark.octagon.fill"
        case .sdkMissing: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        case .unableToEvaluate: "exclamationmark.circle"
        }
    }

    private func color(_ status: ProjectCompatibilityStatus) -> Color {
        switch status {
        case .compatible: .green
        case .incompatible: .red
        case .sdkMissing, .unableToEvaluate: .orange
        case .unknown: .secondary
        }
    }
}

private struct ProjectDiscoverySheet: View {
    @Bindable var container: AppContainer
    let onSelectFolders: () -> Void
    @State private var maximumDepth = 8
    @State private var selection = Set<String>()
    private var discovery: ProjectDiscoveryViewModel { container.projectDiscovery }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discover Projects").font(.title2.weight(.semibold))
                    Text("Scans selected folders for Flutter and Dart packages.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Folders…", action: onSelectFolders)
            }

            if !container.approvedScanDirectories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Approved folders").font(.headline)
                    ForEach(container.approvedScanDirectories) { root in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(root.path).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button { container.removeScanDirectory(root) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Remove \(root.path)")
                        }
                    }
                }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Stepper("Maximum folder depth: \(maximumDepth)", value: $maximumDepth, in: 1...32)
                Spacer()
                if let date = container.lastDiscoveryDate { Text("Last scan \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                if discovery.status == .running || container.preparingProjectDiscovery {
                    ProgressView().controlSize(.small)
                    Text(discovery.progress?.message ?? "Preparing approved folders…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if discovery.status == .running { Button("Cancel Scan", role: .cancel) { discovery.cancel() } }
                } else {
                    Button("Rescan") { container.discoverProjects(maximumDepth: maximumDepth) }
                        .disabled(container.approvedScanDirectories.isEmpty || container.preparingProjectDiscovery)
                    Spacer()
                    Text("\(discovery.scannedDirectories) folders · \(discovery.projects.count) found").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = discovery.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if !discovery.issues.isEmpty, discovery.status != .running {
                DisclosureGroup("\(discovery.issues.count) folders or manifests need attention") {
                    ScrollView { VStack(alignment: .leading, spacing: 5) {
                        ForEach(discovery.issues) { issue in
                            Text("\(issue.id): \(issue.message)").font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 6) }.frame(maxHeight: 90)
                }.font(.caption).foregroundStyle(.secondary)
            }

            if discovery.projects.isEmpty {
                ContentUnavailableView(discovery.status == .running ? "Scanning Selected Folders" : "No Projects Found", systemImage: "folder.badge.questionmark", description: Text("Choose one or more folders, then scan to find projects."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discovery.projects, selection: $selection) { project in
                    DiscoveryProjectRow(project: project, installedSDKs: container.sdkModel?.sdks) { container.ignoreDiscoveredProject(project) }
                        .tag(project.path)
                        .contextMenu { Button("Ignore Project", role: .destructive) { container.ignoreDiscoveredProject(project) } }
                }
            }

            HStack {
                Text("Ignored projects stay hidden on future scans until you add them manually.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import All (\(discovery.projects.count))") {
                    container.importDiscoveredProjects(discovery.projects)
                    selection = []
                }.disabled(discovery.projects.isEmpty)
                Button("Import Selected (\(selection.count))") {
                    let selected = discovery.projects.filter { selection.contains($0.path) }
                    container.importDiscoveredProjects(selected)
                    selection = []
                }.buttonStyle(.borderedProminent).disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .onChange(of: discovery.projects) { _, projects in selection = Set(projects.map(\.path)) }
        .onChange(of: discovery.status) { _, status in if status == .cancelled { selection = Set(discovery.projects.map(\.path)) } }
    }
}

private struct DiscoveryProjectRow: View {
    let project: FlutterProject
    let installedSDKs: [FlutterSDK]?
    let ignore: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.type == .dartPackage ? "shippingbox" : "swift").font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name).font(.headline)
                    Text(project.type.displayName).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                    if project.type != .dartPackage, let version = project.configuredVersion {
                        Label(version, systemImage: "gearshape.2").font(.caption).foregroundStyle(.secondary)
                    }
                    if let constraint = project.dartSDKConstraint { Label(constraint, systemImage: "chevron.left.forwardslash.chevron.right").font(.caption).foregroundStyle(.secondary) }
                }
                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack {
                    if !project.platforms.isEmpty { Text(project.platforms.joined(separator: " · ")) }
                    if let version = project.configuredVersion {
                        let installed = installedSDKs?.contains { $0.name == version || $0.flutterSdkVersion == version } ?? false
                        Text(installed ? "SDK installed" : "SDK not installed")
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Ignore", action: ignore).buttonStyle(.borderless).font(.caption)
        }.padding(.vertical, 3)
    }
}
