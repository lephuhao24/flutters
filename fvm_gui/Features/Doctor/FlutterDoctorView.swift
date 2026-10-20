import AppKit
import SwiftUI

private enum DoctorScope: String, CaseIterable, Identifiable {
    case global = "Global SDK"
    case project = "Project SDK"
    var id: String { rawValue }
}

struct FlutterDoctorView: View {
    @Bindable var container: AppContainer
    @State private var scope: DoctorScope = .global
    @State private var selectedSDKName: String?
    @State private var selectedProjectPath: String?
    @State private var copied = false

    private var model: FlutterDoctorViewModel { container.flutterDoctor }
    private var sdks: [FlutterSDK] { container.sdkModel?.sdks ?? [] }
    private var projects: [FlutterProject] { container.projects.filter { $0.type != .dartPackage } }
    private var selectedProject: FlutterProject? { projects.first { $0.path == selectedProjectPath } }
    private var selectedSDK: FlutterSDK? {
        guard scope == .global else {
            guard let selectedProject else { return nil }
            return sdk(for: selectedProject)
        }
        return sdks.first { $0.name == selectedSDKName } ?? sdks.first(where: \.isGlobal) ?? sdks.first
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isRunning { runningCard }
                    if let report = model.report { reportView(report) }
                    else if !model.isRunning {
                        ContentUnavailableView("No Diagnostics Yet", systemImage: "stethoscope",
                                               description: Text("Select a Flutter SDK or project, then run Flutter Doctor to inspect the local development environment."))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(22)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear(perform: selectInitialTarget)
        .onChange(of: model.activeProjectPath) { _, path in
            guard let path, let project = projects.first(where: { canonical($0.path) == path }) else { return }
            scope = .project
            selectedProjectPath = project.path
        }
        .onChange(of: model.report?.id) { _, _ in
            guard let path = model.report?.projectPath,
                  let project = projects.first(where: { canonical($0.path) == path }) else { return }
            scope = .project
            selectedProjectPath = project.path
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Inspect", selection: $scope) {
                ForEach(DoctorScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            if scope == .global {
                Picker("Flutter SDK", selection: $selectedSDKName) {
                    ForEach(sdks) { sdk in
                        HStack {
                            Text(sdk.name)
                            if sdk.isGlobal { Text("Global") }
                        }.tag(Optional(sdk.name))
                    }
                }
                .frame(maxWidth: 250)
                .disabled(sdks.isEmpty || model.isRunning)
            } else {
                Picker("Project", selection: $selectedProjectPath) {
                    ForEach(projects) { project in Text(project.name).tag(Optional(project.path)) }
                }
                .frame(maxWidth: 250)
                .disabled(projects.isEmpty || model.isRunning)
                if let project = selectedProject {
                    Label(selectedSDK.map { "SDK \($0.name)" } ?? "No effective SDK installed",
                          systemImage: selectedSDK == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(selectedSDK == nil ? .orange : .secondary)
                        .help("Project SDK selection follows its effective FVM version; Doctor does not switch the project SDK.")
                    Text(project.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)
            if model.isRunning {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button { runDoctor() } label: { Label(model.report == nil ? "Run Doctor" : "Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .disabled(scope == .project && selectedProject == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var runningCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Running Flutter Doctor…").font(.headline)
                Text("Output streams to Activity while the check runs. The selected SDK is invoked directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = model.operationID, let entry = container.activity.entries.first(where: { $0.id == id }) {
                Text(entry.output.suffix(120)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func reportView(_ report: FlutterDoctorReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol(report.overallStatus))
                    .font(.system(size: 29, weight: .semibold)).foregroundStyle(color(report.overallStatus))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(report.overallStatus.title).font(.title2.weight(.semibold))
                        if report.executionStatus == .cancelled { Text("Partial").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(report.projectName.map { "\($0) · Flutter \(report.flutterVersion ?? report.sdkName ?? "Unknown")" }
                         ?? "Global SDK · Flutter \(report.flutterVersion ?? report.sdkName ?? "Unknown")")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("SDK: \(report.sdkPath ?? "Not available")")
                        .font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(report.checkedAt, style: .date).font(.caption)
                    Text(report.checkedAt, style: .time).font(.caption)
                    Text(report.duration.formatted(.units(allowed: [.seconds], width: .abbreviated)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let exitCode = report.exitCode { Text("Exit code \(exitCode)").font(.caption.monospacedDigit()).foregroundStyle(exitCode == 0 ? Color.secondary : Color.red) }
                    Text(report.executionStatus.rawValue).font(.caption.weight(.medium)).foregroundStyle(report.executionStatus == .failed ? Color.red : Color.secondary)
                }
            }
            .padding(16)
            .background(color(report.overallStatus).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            if let message = report.message {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Diagnostics", systemImage: "checklist").font(.title3.weight(.semibold))
                if report.categories.isEmpty {
                    ContentUnavailableView("Diagnostics Could Not Be Parsed", systemImage: "text.magnifyingglass",
                                           description: Text("The raw Flutter Doctor output is preserved below. No categories are marked as passed."))
                        .frame(minHeight: 120)
                } else {
                    ForEach(report.categories) { category in categoryRow(category) }
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Complete command output").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.rawOutput, forType: .string)
                            copied = true
                        } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .disabled(report.rawOutput.isEmpty)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(report.rawOutput.isEmpty ? "No output was captured." : report.rawOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 120, maxHeight: 360)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.top, 8)
            } label: {
                Label("Raw Output", systemImage: "text.alignleft").font(.title3.weight(.semibold))
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func categoryRow(_ category: FlutterDoctorCategory) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if category.diagnosticMessages.isEmpty {
                    Text("No additional diagnostic details were reported.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(category.diagnosticMessages.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(category.suggestedActions) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(action.title).font(.callout.weight(.semibold))
                        Text(action.instructions).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if let urlString = action.documentationURL, let url = URL(string: urlString) {
                            Link("Official documentation", destination: url).font(.callout)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                DisclosureGroup("Category raw output") {
                    Text(category.rawOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 6)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: symbol(category.status)).foregroundStyle(color(category.status))
                Text(category.name).font(.headline)
                Spacer()
                Text(category.status.title).font(.caption.weight(.medium)).foregroundStyle(color(category.status))
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func runDoctor() {
        switch scope {
        case .global: model.run(sdk: selectedSDK)
        case .project:
            if let selectedProject { model.runProject(selectedProject, installedSDKs: sdks) }
        }
    }

    private func selectInitialTarget() {
        if let path = model.activeProjectPath ?? model.report?.projectPath,
           let project = projects.first(where: { canonical($0.path) == path }) {
            scope = .project
            selectedProjectPath = project.path
        } else {
            selectedSDKName = sdks.first(where: \.isGlobal)?.name ?? sdks.first?.name
        }
    }

    private func sdk(for project: FlutterProject) -> FlutterSDK? {
        if let version = project.effectiveVersion {
            return sdks.first { $0.name == version } ?? sdks.first { $0.flutterSdkVersion == version }
        }
        return sdks.first(where: \.isGlobal)
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func symbol(_ status: FlutterDiagnosticStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func color(_ status: FlutterDiagnosticStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .unknown: .secondary
        }
    }
}
