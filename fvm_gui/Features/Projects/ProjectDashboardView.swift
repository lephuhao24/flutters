import AppKit
import SwiftUI

struct ProjectDashboardView: View {
    @Bindable var container: AppContainer
    let project: FlutterProject
    let onChangeSDK: () -> Void
    let onRunDoctor: () -> Void
    @State private var consoleExpanded = true
    @State private var copied = false
    @State private var showingProjectExport = false

    private var model: ProjectDashboardViewModel { container.projectDashboard }
    private var compatibility: ProjectCompatibility? { container.compatibilityModel.result(for: project) }
    private var installedSDK: FlutterSDK? {
        let version = compatibility?.selectedFlutterSDK ?? project.effectiveVersion
        return container.sdkModel?.sdks.first { $0.name == version || $0.flutterSdkVersion == version }
    }
    private var projectEntries: [ActivityEntry] {
        container.activity.entries.filter { $0.projectPath == canonicalPath }.prefix(50).reversed()
    }
    private var canonicalPath: String { URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                projectHeader
                environmentSummary
                quickActions
                exportAction
                activityConsole
            }
            .padding(22)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Project Action Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showingProjectExport) {
            ProjectExportView(project: project, service: container.projectExport,
                              approvedDirectories: container.approvedScanDirectories,
                              projectBookmarks: container.projectBookmarks)
                .frame(minWidth: 760, minHeight: 620)
        }
    }

    private var exportAction: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label("Project Archive", systemImage: "archivebox")
                    .font(.title3.weight(.semibold))
                Text("Create a ZIP of the project source with Git and Flutter cache exclusions.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingProjectExport = true } label: { Label("Export ZIP…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(project.name).font(.largeTitle.weight(.semibold))
                        Text(project.type.displayName)
                            .font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(project.path).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                }
                Spacer(minLength: 10)
                Button(action: onChangeSDK) { Label("Change SDK…", systemImage: "arrow.triangle.swap") }
                    .disabled(project.type == .dartPackage || container.sdkModel?.sdks.isEmpty != false || container.busy)
            }
            HStack(spacing: 16) {
                metadataChip("Selected SDK", value: compatibility?.selectedFlutterSDK ?? project.effectiveVersion)
                metadataChip("Flutter Version", value: compatibility?.selectedFlutterVersion ?? installedSDK?.flutterSdkVersion)
                metadataChip("Installation", value: installationDescription)
                if let result = compatibility {
                    Label(result.status.title, systemImage: statusSymbol(result.status))
                        .font(.callout.weight(.medium)).foregroundStyle(statusColor(result.status))
                        .help(result.explanation)
                } else {
                    Label("Checking compatibility", systemImage: "hourglass").foregroundStyle(.secondary)
                }
            }
            if let issue = project.issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var environmentSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Environment", systemImage: "gearshape.2").font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                environmentRow("Configured Flutter", project.configuredVersion)
                environmentRow("Effective Flutter", compatibility?.effectiveFlutterVersion ?? project.effectiveVersion)
                environmentRow("Configuration source", configurationDescription)
                environmentRow("Bundled Dart", compatibility?.bundledDartSDKVersion)
                environmentRow("Dart SDK constraint", project.dartSDKConstraint)
                environmentRow("Flutter SDK constraint", project.flutterSDKConstraint)
                environmentRow("Supported platforms", project.platforms.isEmpty ? nil : project.platforms.joined(separator: " · "))
                environmentRow("SDK directory", installedSDK?.directory)
            }
            if let result = compatibility, result.status != .compatible {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.explanation).font(.callout).textSelection(.enabled)
                    Text(result.recommendedAction).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor(result.status).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Actions", systemImage: "bolt.fill").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(ProjectFlutterCommand.allCases) { command in actionButton(command) }
                doctorButton
            }
            Divider().padding(.vertical, 2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], alignment: .leading, spacing: 10) {
                ideButton(.finder, symbol: "folder")
                ideButton(.terminal, symbol: "terminal")
                ideButton(.visualStudioCode, symbol: "chevron.left.forwardslash.chevron.right")
                ideButton(.androidStudio, symbol: "cpu")
                ideButton(.xcode, symbol: "hammer")
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var activityConsole: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $consoleExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent project commands").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(projectEntries.map(\.output).joined(separator: "\n"), forType: .string)
                            copied = true
                        } label: { Label(copied ? "Copied" : "Copy Output", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .disabled(projectEntries.isEmpty)
                        Button("Clear Completed") { model.clearCompleted(for: project) }
                            .disabled(!projectEntries.contains { $0.operationStatus != .running })
                    }
                    if projectEntries.isEmpty {
                        ContentUnavailableView("No Project Activity", systemImage: "terminal", description: Text("Quick action output will appear here."))
                            .frame(maxWidth: .infinity, minHeight: 110)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(projectEntries) { entry in activityEntry(entry) }
                                }
                                .padding(10)
                            }
                            .frame(minHeight: 150, maxHeight: 330)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .onChange(of: projectEntries.map(\.id)) { _, ids in
                                if let first = ids.first { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(first, anchor: .top) } }
                            }
                            .onChange(of: projectEntries.map(\.output)) { _, _ in
                                if let first = projectEntries.first?.id { proxy.scrollTo(first, anchor: .top) }
                            }
                        }
                    }
                    Text("Activity history is limited to the latest 100 operations and 200 KB per output.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    Label("Activity Console", systemImage: "terminal")
                    Spacer()
                    Text("\(projectEntries.count) entries").font(.caption).foregroundStyle(.secondary)
                }.font(.title3.weight(.semibold))
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func actionButton(_ command: ProjectFlutterCommand) -> some View {
        let running = model.isRunning(command, for: project)
        return Button {
            if running {
                if let entry = projectEntries.first(where: { $0.operationStatus == .running && $0.command.hasSuffix(command.arguments.joined(separator: " ")) }) {
                    model.cancel(entry)
                }
            } else { model.run(command, for: project) }
        } label: {
            HStack {
                if running { ProgressView().controlSize(.small) }
                else { Image(systemName: actionSymbol(command)) }
                Text(running ? "Cancel \(command.title)" : command.title).lineLimit(1)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(!running && (project.type == .dartPackage || container.installation == nil || container.busy))
        .help(project.type == .dartPackage ? "Flutter commands are unavailable for Dart-only packages" : "Runs `fvm flutter \(command.arguments.joined(separator: " "))` in \(project.path)")
    }

    private var doctorButton: some View {
        let running = container.flutterDoctor.isRunning(for: project)
        return Button {
            if running { container.flutterDoctor.cancel() }
            else { onRunDoctor() }
        } label: {
            HStack {
                if running { ProgressView().controlSize(.small) }
                else { Image(systemName: "stethoscope") }
                Text(running ? "Cancel Flutter Doctor" : "Flutter Doctor").lineLimit(1)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled((project.type == .dartPackage || container.installation == nil) && !running)
        .help("Inspect this project's effective Flutter SDK and open the Flutter Doctor dashboard")
    }

    private func ideButton(_ ide: ProjectIDE, symbol: String) -> some View {
        Button { Task { await model.open(ide, for: project) } } label: {
            Label("Open in \(ide.title)", systemImage: symbol).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(!model.ideOpening.isAvailable(ide))
        .help(ide == .xcode ? "Open the project's iOS workspace in Xcode" : "Open this project in \(ide.title)")
    }

    private func activityEntry(_ entry: ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entry.command).font(.system(.caption, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                Spacer()
                Text(entry.started, style: .time).font(.caption).foregroundStyle(.secondary)
                Text(entry.status).font(.caption.weight(.medium)).foregroundStyle(entry.operationStatus == .failed ? .red : .secondary)
                if let code = entry.exitCode { Text("Exit \(code)").font(.caption.monospacedDigit()).foregroundStyle(code == 0 ? .green : .red) }
                if let duration = entry.duration { Text(duration.formatted(.units(allowed: [.seconds], width: .abbreviated))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if entry.operationStatus == .running {
                    Button("Cancel") { model.cancel(entry) }.buttonStyle(.borderless)
                }
            }
            Text(entry.output.isEmpty ? (entry.operationStatus == .running ? "Waiting for output…" : "No output") : entry.output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .id(entry.id)
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var installationDescription: String {
        guard let installedSDK else { return project.effectiveVersion == nil ? "No SDK selected" : "Not installed" }
        return installedSDK.isSetup ? (installedSDK.isGlobal ? "Installed · Global" : "Installed") : "Setup incomplete"
    }

    private var configurationDescription: String? {
        guard let source = compatibility?.configurationSource ?? project.configurationSource else { return nil }
        return source == URL(fileURLWithPath: project.path).appendingPathComponent(".fvmrc").path ? "Local .fvmrc" : "Inherited from \(source)"
    }

    private func environmentRow(_ title: String, _ value: String?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "Not available")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(value?.isEmpty == false ? Color.primary : Color.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataChip(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "Not available").font(.callout.weight(.medium))
        }
    }

    private func actionSymbol(_ command: ProjectFlutterCommand) -> String {
        switch command {
        case .pubGet: "shippingbox"
        case .clean: "sparkles"
        case .pubOutdated: "arrow.up.circle"
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
}
