import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BuildReleaseView: View {
    let project: FlutterProject
    let fvm: FVMInstallation
    let executor: any CLIExecuting
    let sdk: FlutterSDK?
    @Bindable var store: BuildReleaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: BuildReleaseViewModel
    @State private var showingManualFlavorField = false
    @State private var manualFlavorText = ""
    @State private var showingManualEntrypointField = false
    @State private var manualEntrypointText = ""
    @State private var showingDiagnostics = false
    @State private var showingLocalSchemes = false
    @State private var defineText = ""
    @State private var presetName = ""
    @State private var searchText = ""
    @State private var selectedHistory: UUID?
    @State private var selectedLog = ""
    @State private var showingHistory = false
    @State private var lastCopied = false
    @State private var previewBuildID = UUID()
    @State private var symbolicationRecord: BuildHistoryRecord?
    @State private var pendingArchiveDeletion: BuildHistoryRecord?
    @State private var storageActionError: String?
    @State private var isExportingRelease = false
    @State private var releaseExportTask: Task<Void, Never>?

    init(project: FlutterProject, fvm: FVMInstallation, executor: any CLIExecuting, sdk: FlutterSDK?, store: BuildReleaseStore) {
        self.project = project
        self.fvm = fvm
        self.executor = executor
        self.sdk = sdk
        self.store = store
        let sdkVer = sdk?.name ?? project.effectiveVersion ?? "project SDK"
        _viewModel = State(initialValue: store.makeViewModel(project: project, sdkVersion: sdkVer, executor: executor))
    }

    private var configuration: BuildConfiguration {
        get { viewModel.configuration }
        nonmutating set { viewModel.configuration = newValue }
    }

    private var buildService: FlutterBuildService { FlutterBuildService(fvm: fvm, sdkDirectory: sdk?.directory, executor: executor) }
    private var activeRecord: BuildHistoryRecord? { store.activeID.flatMap { id in store.history.first { $0.id == id } } }
    private var displayedRecord: BuildHistoryRecord? { selectedHistory.flatMap { id in store.history.first { $0.id == id } } }
    private var logs: String { displayedRecord?.id == store.activeID ? store.liveLog : (displayedRecord == nil ? store.liveLog : selectedLog) }
    private var visibleLogs: String { searchText.isEmpty ? logs : logs.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(searchText) }.joined(separator: "\n") }
    private var stages: [BuildStage] { [.preparing, .validating, .resolvingDependencies, .compiling, .packaging, .archiving, .finalizing, .completed] }
    private var stableProjectIdentity: String { ReleaseStorageService.stableProjectID(at: URL(fileURLWithPath: project.path), projectName: project.name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                configurationPanel.frame(width: 400)
                Divider().padding(.horizontal, 16)
                if showingHistory { historyPanel } else { activityPanel }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 720)
        .task {
            await viewModel.refreshDiscovery(force: false)
        }
        .task(id: selectedHistory) {
            guard let record = displayedRecord else { selectedLog = ""; return }
            selectedLog = store.readLog(record)
        }
        .sheet(item: $symbolicationRecord) { record in
            DartSymbolicationView(record: record, storage: store.releaseStorage, executor: executor)
        }
        .alert("Delete Archived Release?", isPresented: Binding(
            get: { pendingArchiveDeletion != nil },
            set: { if !$0 { pendingArchiveDeletion = nil } }
        )) {
            Button("Delete Release", role: .destructive) {
                guard let record = pendingArchiveDeletion else { return }
                Task {
                    do { try await store.deleteArchivedRelease(record) }
                    catch { storageActionError = error.localizedDescription }
                    pendingArchiveDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingArchiveDeletion = nil }
        } message: {
            Text("This removes the archived artifacts and symbols from disk. The Build History record remains. If these are the only copies of the Dart symbol files, you will no longer be able to symbolicate obfuscated crashes.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Build Release").font(.title2.weight(.semibold))
                Text("\(project.name)  ·  Flutter \(sdk?.flutterSdkVersion ?? "version unavailable")").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("View", selection: $showingHistory) {
                Text("Build").tag(false)
                Text("History").tag(true)
            }.pickerStyle(.segmented).frame(width: 180)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var configurationPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionTitle("CONFIGURATION")
                    VStack(alignment: .leading, spacing: 13) {
                        labeledPicker(
                            "Platform",
                            selection: Binding(
                                get: { viewModel.configuration.platform },
                                set: { newPlatform in
                                    Task { await viewModel.selectPlatform(newPlatform) }
                                }
                            )
                        ) {
                            ForEach(ReleasePlatform.allCases) { Text($0.title).tag($0) }
                        }

                        labeledPicker("Build mode", selection: $viewModel.configuration.buildMode) {
                            Text("Release").tag("release")
                            Text("Profile").tag("profile")
                            Text("Debug").tag("debug")
                        }

                        flavorPickerSection
                        entrypointPickerSection

                        HStack(alignment: .top, spacing: 10) {
                            labeledField("Version name", text: $viewModel.configuration.buildName, prompt: "1.0.0")
                            labeledField("Build number", text: $viewModel.configuration.buildNumber, prompt: "1")
                        }
                    }

                    diagnosticsSection

                    DisclosureGroup("Build options") {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("Obfuscate Dart code", isOn: Binding(
                                get: { viewModel.configuration.obfuscate },
                                set: { enabled in
                                    viewModel.configuration.obfuscate = enabled
                                    if enabled { viewModel.configuration.generateDebugSymbols = true }
                                }
                            ))
                            Toggle("Generate Debug Symbols", isOn: $viewModel.configuration.generateDebugSymbols)
                                .disabled(viewModel.configuration.obfuscate)
                            if viewModel.configuration.obfuscate {
                                Text("Debug symbols are required for obfuscated builds and will be stored with this release.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Archive Release", isOn: $viewModel.configuration.archiveRelease)
                            HStack {
                                Text("Storage").font(.callout.weight(.medium))
                                Spacer()
                                Text(storageDirectory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([storageDirectory]) }
                                    .buttonStyle(.link)
                            }
                            Text("Next release: \(previewReleaseDirectory.path)")
                                .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                            Toggle("Tree-shake icons", isOn: $viewModel.configuration.treeShakeIcons)
                            if viewModel.configuration.platform == .androidAPK {
                                Toggle("Split APKs per ABI", isOn: $viewModel.configuration.splitPerABI)
                            }
                            if viewModel.configuration.platform == .iOSIPA {
                                pathField(
                                    "Export options plist",
                                    value: Binding(
                                        get: { viewModel.configuration.exportOptionsPlist ?? "" },
                                        set: { viewModel.configuration.exportOptionsPlist = $0.isEmpty ? nil : $0 }
                                    ),
                                    directory: false
                                )
                            }
                        }.padding(.top, 9)
                    }

                    DisclosureGroup("Dart defines") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($viewModel.configuration.defines) { $define in
                                HStack(spacing: 6) {
                                    TextField("KEY", text: $define.key)
                                    TextField("Value", text: $define.value)
                                    Button(role: .destructive) {
                                        viewModel.configuration.defines.removeAll { $0.id == define.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }.buttonStyle(.plain)
                                }
                            }
                            HStack {
                                TextField("KEY=VALUE", text: $defineText)
                                Button("Add") { addDefine() }.disabled(!defineText.contains("="))
                            }
                            pathField(
                                "Dart define file",
                                value: Binding(
                                    get: { viewModel.configuration.defineFile ?? "" },
                                    set: { viewModel.configuration.defineFile = $0.isEmpty ? nil : $0 }
                                ),
                                directory: false
                            )
                            Text("Define values are hidden in the command preview.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 9)
                    }

                    DisclosureGroup("Presets and output") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Preset name", text: $presetName)
                                Button("Save") { store.savePreset(viewModel.configuration, name: presetName) }
                                    .disabled(presetName.isEmpty)
                            }
                            if let values = store.presets[project.id], !values.isEmpty {
                                ForEach(values) { preset in
                                    HStack {
                                        Button(preset.name) {
                                            viewModel.configuration = preset.configuration
                                            presetName = preset.name
                                            Task { await viewModel.refreshDiscovery(force: false) }
                                        }
                                        Spacer()
                                        Button(role: .destructive) { store.removePreset(preset) } label: {
                                            Image(systemName: "trash")
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            pathField(
                                "Output folder",
                                value: Binding(
                                    get: { viewModel.configuration.outputDestination ?? "" },
                                    set: { viewModel.configuration.outputDestination = $0.isEmpty ? nil : $0 }
                                ),
                                directory: true
                            )
                        }.padding(.top, 9)
                    }

                    DisclosureGroup("Command preview") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(previewCommand)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(previewCommand, forType: .string)
                                lastCopied = true
                            }
                            .buttonStyle(.link).font(.caption)
                        }.padding(.top, 9)
                    }

                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 10).padding(.bottom, 12)
            }.disabled(store.activeTask != nil)

            Divider().padding(.top, 8)
            HStack {
                Button {
                    if store.activeTask != nil { store.cancel() } else { startBuild() }
                } label: {
                    Label(
                        store.activeTask == nil ? "Build Release" : (store.isCancelling ? "Cancelling…" : "Cancel Build"),
                        systemImage: store.activeTask == nil ? "hammer" : "stop.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(store.activeTask == nil ? .accentColor : .red)
                .disabled((store.activeTask == nil && (sdk == nil || !viewModel.isEntrypointValidForBuild || !viewModel.isFlavorValidForBuild)) || store.isCancelling)
                Spacer()
            }.padding(.top, 12)
        }
    }

    private var flavorPickerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Flavor / Scheme").font(.callout.weight(.medium))
                Spacer()
                Button {
                    showingManualFlavorField.toggle()
                    if showingManualFlavorField {
                        manualFlavorText = viewModel.configuration.flavor ?? ""
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Enter a custom flavor or scheme name manually")

                Button {
                    viewModel.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh Schemes and Entrypoints")
                .disabled(viewModel.isDiscovering)
                .help("Refresh schemes, flavors, and Dart entrypoints")
            }

            Picker(
                "Flavor / Scheme",
                selection: Binding(
                    get: { viewModel.configuration.flavor },
                    set: { viewModel.selectFlavor($0, isManual: false) }
                )
            ) {
                Text("No Flavor").tag(nil as String?)
                ForEach(viewModel.flavors) { flavor in
                    let scheme = viewModel.configuration.platform == .iOSIPA
                        ? viewModel.diagnostics.discoveredSchemes.first(where: { $0.name == (flavor.schemeName ?? flavor.name) })
                        : nil
                    let details = scheme.map { " · \($0.targetNames.joined(separator: ", ")) · \($0.archiveConfiguration ?? "No Archive config") · Shared" } ?? ""
                    Text((flavor.confidence == .potentialFlavor ? "\(flavor.name) (Potential)" : flavor.name) + details)
                        .tag(Optional(flavor.name))
                }
                if let current = viewModel.configuration.flavor,
                   !current.isEmpty,
                   !viewModel.flavors.contains(where: { $0.name == current }) {
                    Text("\(current) (Manual)").tag(Optional(current))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isDiscovering || store.activeTask != nil)

            if showingManualFlavorField {
                HStack(spacing: 6) {
                    TextField("Custom flavor or scheme", text: $manualFlavorText)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        let trimmed = manualFlavorText.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.selectFlavor(trimmed.isEmpty ? nil : trimmed, isManual: !trimmed.isEmpty)
                        showingManualFlavorField = false
                    }
                }
            }

            if viewModel.isDiscovering {
                Label("Discovering flavors and schemes…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let discoveryError = viewModel.discoveryError {
                Label(discoveryError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.flavors.isEmpty {
                Text(viewModel.diagnostics.emptyStateExplanation ?? "No flavors or schemes were detected. Use 'No Flavor' for standard builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let flavor = viewModel.flavors.first(where: { $0.name == viewModel.configuration.flavor }) {
                Text("\(flavor.confidence.title) · \(flavor.source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.configuration.platform == .iOSIPA,
                   let scheme = viewModel.diagnostics.discoveredSchemes.first(where: { $0.name == (flavor.schemeName ?? flavor.name) }) {
                    Text("\(scheme.targetNames.joined(separator: ", ")) · \(scheme.archiveConfiguration ?? "Archive configuration unavailable") · Shared")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if viewModel.configuration.platform == .iOSIPA, !viewModel.diagnostics.localSchemes.isEmpty {
                Button(showingLocalSchemes ? "Hide local schemes" : "Reveal local schemes (\(viewModel.diagnostics.localSchemes.count))") {
                    showingLocalSchemes.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                if showingLocalSchemes {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(viewModel.diagnostics.localSchemes.enumerated()), id: \.offset) { _, scheme in
                            Text(scheme).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Local schemes are user-specific and are not selectable for portable builds.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let validation = viewModel.flavorValidationMessage {
                Label(validation, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var entrypointPickerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Dart entrypoint").font(.callout.weight(.medium))
                Spacer()
                Button {
                    showingManualEntrypointField.toggle()
                    if showingManualEntrypointField {
                        manualEntrypointText = viewModel.configuration.entrypoint
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Enter a custom project-relative Dart entrypoint path")
            }

            Picker(
                "Dart entrypoint",
                selection: Binding(
                    get: { viewModel.configuration.entrypoint },
                    set: { viewModel.selectEntrypoint($0, isManual: true) }
                )
            ) {
                ForEach(viewModel.detectedEntrypoints) { entry in
                    Text(entry.confidence == .potential ? "\(entry.path) (Potential)" : entry.path)
                        .tag(entry.path)
                }
                if !viewModel.entrypoints.contains(viewModel.configuration.entrypoint) {
                    Text("\(viewModel.configuration.entrypoint) (Manual)")
                        .tag(viewModel.configuration.entrypoint)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(store.activeTask != nil)

            if showingManualEntrypointField {
                HStack(spacing: 6) {
                    TextField("lib/main_custom.dart", text: $manualEntrypointText)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        viewModel.selectEntrypoint(manualEntrypointText, isManual: true)
                        showingManualEntrypointField = false
                    }
                    Button("Auto") {
                        viewModel.clearManualEntrypointOverride()
                        showingManualEntrypointField = false
                    }
                    .help("Reset to automatically suggested entrypoint for current flavor")
                }
            }

            if let message = viewModel.entrypointValidationMessage {
                Label(
                    message,
                    systemImage: viewModel.isEntrypointValidForBuild ? "exclamationmark.circle" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(viewModel.isEntrypointValidForBuild ? .orange : .red)
                .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.detectedEntrypoints.isEmpty && !viewModel.isDiscovering {
                Label("No Dart entrypoints with main() were discovered under lib/.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var diagnosticsSection: some View {
        DisclosureGroup("Discovery diagnostics", isExpanded: $showingDiagnostics) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Container:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(viewModel.diagnostics.containerPath ?? "None detected")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Refresh") {
                        viewModel.refresh(force: true)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(viewModel.isDiscovering)
                }

                if viewModel.configuration.platform == .iOSIPA {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Discovered schemes (\(viewModel.diagnostics.discoveredSchemes.count)):")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if viewModel.diagnostics.discoveredSchemes.isEmpty {
                            Text("None")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.diagnostics.discoveredSchemes) { scheme in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: schemeConfidenceIcon(scheme.confidence))
                                        .font(.caption)
                                        .foregroundStyle(schemeConfidenceColor(scheme.confidence))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(scheme.name) — \(scheme.confidence.title)")
                                            .font(.system(.caption, design: .monospaced))
                                        if let explanation = scheme.explanation {
                                            Text(explanation)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Build configurations (\(viewModel.diagnostics.discoveredBuildConfigurations.count)):")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.diagnostics.discoveredBuildConfigurations.isEmpty ? "None" : viewModel.diagnostics.discoveredBuildConfigurations.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Validated flavors (\(viewModel.flavors.count)):")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(viewModel.flavors.isEmpty ? "None" : viewModel.flavors.map { "\($0.name) (\($0.confidence == .confirmedFlavor ? "Confirmed" : "Potential"))" }.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Discovered entrypoints (\(viewModel.detectedEntrypoints.count)):")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(viewModel.detectedEntrypoints.isEmpty ? "None" : viewModel.detectedEntrypoints.map(\.path).joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                let allWarnings = viewModel.diagnostics.warnings + viewModel.entrypointDiagnostics.warnings
                if !allWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Warnings:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(allWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                let allErrors = viewModel.diagnostics.errors + viewModel.entrypointDiagnostics.errors
                if !allErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Errors:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        ForEach(allErrors, id: \.self) { err in
                            Label(err, systemImage: "xmark.octagon")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func schemeConfidenceIcon(_ confidence: FlavorConfidence) -> String {
        switch confidence {
        case .confirmedFlavor: "checkmark.seal.fill"
        case .potentialFlavor: "questionmark.circle.fill"
        case .ordinaryScheme: "gearshape"
        case .invalidConfiguration: "exclamationmark.triangle.fill"
        }
    }

    private func schemeConfidenceColor(_ confidence: FlavorConfidence) -> Color {
        switch confidence {
        case .confirmedFlavor: .green
        case .potentialFlavor: .orange
        case .ordinaryScheme: .secondary
        case .invalidConfiguration: .red
        }
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let record = displayedRecord {
                historyDetail(record)
            } else {
                buildStatus
                Divider()
                logViewer
                buildActions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, 2)
    }

    private var buildStatus: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: platformIcon(viewModel.configuration.platform)).font(.title2).foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.title3.weight(.semibold))
                    Text([viewModel.configuration.flavor, viewModel.configuration.buildMode.capitalized, "Flutter \(sdk?.flutterSdkVersion ?? "unknown")"].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.activeTask != nil { TimelineView(.periodic(from: .now, by: 1)) { context in Text(elapsed(at: context.date)).monospacedDigit().foregroundStyle(.secondary) }.accessibilityLabel("Elapsed build time") }
                else if let duration = activeRecord?.duration { Text(durationText(duration)).monospacedDigit().foregroundStyle(.secondary) }
            }
            if store.activeTask != nil { ProgressView().controlSize(.regular).accessibilityLabel("Build in progress") }
            else if store.stage == .completed { ProgressView(value: 1).tint(.green).accessibilityLabel("Build completed") }
            Text(stageDescription).font(.callout.weight(.medium)).lineLimit(2)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) { ForEach(Array(stages.prefix(4)), id: \.self) { stage in stageCell(stage) } }
                VStack(alignment: .leading, spacing: 7) { ForEach(Array(stages.dropFirst(4)), id: \.self) { stage in stageCell(stage) } }
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BUILD LOGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                TextField("Search logs", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 190)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(logs, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy all build logs")
                Button { saveLog() } label: { Image(systemName: "square.and.arrow.down") }.help("Save build logs")
            }
            ZStack(alignment: .topLeading) {
                BuildLogConsole(text: visibleLogs)
                if logs.isEmpty {
                    Text(store.activeTask == nil ? "Build output will appear here." : "Waiting for build output…")
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).padding(14).allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 260)
        }
    }

    @ViewBuilder private var buildActions: some View {
        if let artifact = store.artifact {
            VStack(alignment: .leading, spacing: 8) {
                Label("Build succeeded", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                Text(artifact.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([artifact]) }
                    Button("Export To…") { export(artifact) }
                    Button("View History") { showingHistory = true; selectedHistory = activeRecord?.id }
                }
            }
        } else if store.stage == .failed, let error = store.error {
            Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            HStack { Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error + "\n\n" + logs, forType: .string) }; Button("Retry Build") { startBuild() } }
        } else if store.stage == .cancelled {
            Label("Build cancelled. Partial logs are preserved.", systemImage: "stop.circle").foregroundStyle(.secondary)
            Button("Rebuild") { startBuild() }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Build History").font(.title3.weight(.semibold)); Spacer(); Button("Clear Selection") { selectedHistory = nil } }
            List(selection: $selectedHistory) {
                ForEach(store.history.filter { $0.projectIdentity == stableProjectIdentity || ($0.projectIdentity == nil && $0.configuration.projectID == project.id) }) { record in
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon(record.status)).font(.title3).foregroundStyle(statusColor(record.status))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(project.name) · \(record.configuration.platform.title) · \(record.configuration.flavor ?? "No Flavor")").font(.callout.weight(.medium))
                            Text("\(record.configuration.buildMode.capitalized) · \(record.configuration.buildName.isEmpty ? "Version unavailable" : record.configuration.buildName) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let status = record.archiveStatus {
                                Text(archiveSummary(record, status: status))
                                    .font(.caption2).foregroundStyle(status == .archived ? Color.secondary : Color.orange)
                            }
                            if let buildStatus = record.buildStatus {
                                Text("Flutter: \(buildStatus.rawValue.capitalized)")
                                    .font(.caption2).foregroundStyle(buildStatus == .succeeded ? Color.secondary : Color.orange)
                            }
                        }
                        Spacer()
                        if let duration = record.duration { Text(durationText(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        if let path = record.artifactPath, FileManager.default.fileExists(atPath: path) { Image(systemName: "shippingbox.fill").foregroundStyle(.secondary).help("Artifact available") }
                    }.tag(record.id).contextMenu {
                        Button("Load Configuration") {
                            viewModel.configuration = record.configuration
                            showingHistory = false
                            Task { await viewModel.refreshDiscovery(force: false) }
                        }
                        Button("Remove from History", role: .destructive) { store.removeHistory(record.id); if selectedHistory == record.id { selectedHistory = nil } }
                    }
                }
            }.listStyle(.inset)
            if let record = displayedRecord { historyDetail(record, logContent: logs).frame(minHeight: 250) }
            else if store.history.isEmpty { ContentUnavailableView("No Builds Yet", systemImage: "clock", description: Text("Completed and cancelled builds will appear here.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func historyDetail(_ record: BuildHistoryRecord, logContent: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("\(record.configuration.platform.title) · \(record.configuration.flavor ?? "No Flavor")", systemImage: platformIcon(record.configuration.platform)).font(.headline); Spacer(); Text(record.status.rawValue.capitalized).foregroundStyle(statusColor(record.status)) }
            if let buildStatus = record.buildStatus {
                Label("Flutter build: \(buildStatus.rawValue.capitalized)", systemImage: buildStatus == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(buildStatus == .succeeded ? Color.secondary : Color.orange)
            }
            Text("\(record.startedAt.formatted(date: .long, time: .shortened)) · \(record.duration.map(durationText) ?? "In progress") · Flutter \(record.sdkLabel)").font(.caption).foregroundStyle(.secondary)
            if let path = record.artifactPath { Text("Artifact: \(path)").font(.caption).textSelection(.enabled) }
            if let releasePath = record.releaseDirectory {
                Text("Release archive: \(releasePath)").font(.caption).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Reveal Release") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: releasePath)]) }
                    if let artifact = archivedArtifactURL(record, index: 0) {
                        Button("Open Artifact") { NSWorkspace.shared.open(artifact) }
                        Button("Copy Artifact Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(artifact.path, forType: .string) }
                    }
                    if !(record.archivedSymbolFiles ?? []).isEmpty {
                        Button("Open Symbols") { NSWorkspace.shared.activateFileViewerSelecting(symbolURLs(record)) }
                        Button("Symbolize Crash Log") { symbolicationRecord = record }
                    }
                    Menu("Export Release") {
                        Button("Artifact Only (ZIP)") { exportRelease(record, contents: .artifactsOnly) }
                        Button("Artifacts and Metadata (ZIP)") { exportRelease(record, contents: .artifactsAndMetadata) }
                        Button("Complete Release (ZIP)") { exportRelease(record, contents: .complete) }
                        Button("Complete Release Folder…") { exportReleaseFolder(record) }
                    }.disabled(isExportingRelease)
                    Button("Delete Archive…", role: .destructive) { pendingArchiveDeletion = record }
                }.buttonStyle(.borderless)
                if record.archiveStatus == .partial || record.archiveStatus == .failed {
                    Label("This release is incomplete. Check its archived log and metadata before distribution.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if isExportingRelease {
                HStack {
                    ProgressView("Exporting release…").controlSize(.small)
                    Button("Cancel Export") { releaseExportTask?.cancel() }
                }
            }
            if let storageActionError { Text(storageActionError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let error = record.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            TextEditor(text: .constant(logContent ?? record.log)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusTitle: String {
        if store.isCancelling { return "Cancelling build…" }
        if store.activeTask != nil { return "Building \(viewModel.configuration.platform.title)" }
        switch store.stage { case .completed: return "Build Succeeded"; case .failed: return "Build Failed"; case .cancelled: return "Build Cancelled"; default: return "Ready to Build" }
    }
    private var stageDescription: String {
        if store.isCancelling { return "Stopping Flutter and its child processes…" }
        if store.activeTask != nil { return store.currentTask.isEmpty ? "Preparing build…" : store.currentTask }
        return store.stage.title
    }
    private var statusColor: Color { store.stage == .failed ? .red : store.stage == .completed ? .green : .accentColor }
    private func stageCell(_ stage: BuildStage) -> some View {
        let currentIndex = stages.firstIndex(of: store.stage) ?? -1
        let index = stages.firstIndex(of: stage) ?? 0
        let done = store.stage == .completed || (currentIndex > index && currentIndex >= 0)
        let current = store.stage == stage
        return HStack(spacing: 7) {
            Image(systemName: done ? "checkmark.circle.fill" : current ? (store.stage == .failed ? "xmark.circle.fill" : "circle.inset.filled") : "circle")
                .foregroundStyle(done ? .green : current ? statusColor : Color.secondary)
            Text(stage.title).font(.caption).foregroundStyle(current ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    private var previewConfiguration: BuildConfiguration {
        var value = viewModel.configuration
        if value.obfuscate { value.generateDebugSymbols = true }
        if value.splitDebugInfo?.isEmpty == false { value.generateDebugSymbols = true }
        if value.generateDebugSymbols {
            value.splitDebugInfo = previewReleaseDirectory.appendingPathComponent("symbols", isDirectory: true).path
        }
        return value
    }
    private var storageDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: ReleaseStorageService.customPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return (try? ReleaseStorageService.defaultStorageURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("Releases", isDirectory: true)
    }
    private var previewReleaseDirectory: URL {
        ReleaseStorageService.previewReleaseURL(
            root: storageDirectory,
            configuration: previewConfigurationBase,
            project: URL(fileURLWithPath: project.path),
            projectName: project.name,
            buildID: previewBuildID
        )
    }
    private var previewConfigurationBase: BuildConfiguration {
        var value = viewModel.configuration
        if value.obfuscate { value.generateDebugSymbols = true }
        return value
    }
    private var maskedCommand: String {
        guard let args = try? previewConfiguration.arguments() else { return "Invalid configuration" }
        var safe: [String] = []; var index = 0
        while index < args.count {
            let argument = args[index]; safe.append(quote(argument)); index += 1
            if ["--dart-define", "--dart-define-from-file"].contains(argument), index < args.count {
                if argument == "--dart-define" { safe.append(quote((args[index].split(separator: "=", maxSplits: 1).first.map(String.init) ?? "DEFINE") + "=••••••")) }
                else { safe.append("••••••") }
                index += 1
            } else if ["-t", "--flavor", "--build-name", "--build-number", "--split-debug-info", "--export-options-plist"].contains(argument), index < args.count {
                safe.append(quote(args[index])); index += 1
            }
        }
        return safe.joined(separator: " ")
    }
    private var previewCommand: String {
        let executable = sdk.map { URL(fileURLWithPath: $0.directory, isDirectory: true).appendingPathComponent("bin/flutter").path } ?? "Flutter SDK unavailable"
        return "\(quote(executable)) \(maskedCommand)"
    }
    private func quote(_ value: String) -> String { value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? value : "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
    private func sectionTitle(_ value: String) -> some View { Text(value).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.7) }
    private func labeledPicker<Selection: Hashable, Content: View>(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout.weight(.medium)); Picker(title, selection: selection, content: content).labelsHidden().pickerStyle(.menu) }
    }
    private func labeledField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout.weight(.medium)); TextField(prompt, text: text).textFieldStyle(.roundedBorder) }
    }
    private func platformIcon(_ platform: ReleasePlatform) -> String { platform.isAndroid ? "phone" : platform == .iOSIPA ? "iphone" : "desktopcomputer" }
    private func statusIcon(_ status: BuildJobStatus) -> String { switch status { case .running: "arrow.triangle.2.circlepath"; case .succeeded: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .cancelled: "stop.circle" } }
    private func statusColor(_ status: BuildJobStatus) -> Color { switch status { case .running: .accentColor; case .succeeded: .green; case .failed: .red; case .cancelled: .secondary } }
    private func elapsed(at date: Date) -> String { durationText(date.timeIntervalSince(store.startedAt ?? date)) }
    private func durationText(_ value: TimeInterval) -> String { let total = max(0, Int(value)); return String(format: "%02d:%02d", total / 60, total % 60) }

    private func startBuild() {
        store.saveConfiguration(viewModel.configuration)
        store.start(config: viewModel.configuration, project: URL(fileURLWithPath: project.path), projectName: project.name, sdkLabel: sdk?.flutterSdkVersion ?? sdk?.name ?? "Unknown", service: buildService, buildID: previewBuildID)
        Task {
            await store.activeTask?.value
            previewBuildID = UUID()
        }
    }
    private func addDefine() {
        let pair = defineText.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { return }
        viewModel.configuration.defines.append(BuildDefine(key: pair[0], value: pair[1]))
        defineText = ""
    }
    private func pathField(_ title: String, value: Binding<String>, directory: Bool) -> some View {
        HStack {
            TextField(title, text: value)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory
                panel.canChooseFiles = !directory
                panel.canCreateDirectories = directory
                if !directory { panel.allowedContentTypes = [.propertyList] }
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            }
        }
    }
    private func export(_ artifact: URL) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = artifact.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { guard !FileManager.default.fileExists(atPath: destination.path) else { throw BuildValidationError("The destination already exists. Choose another name.") }; try FileManager.default.copyItem(at: artifact, to: destination) }
        catch { store.error = "Build succeeded, but export failed: \(error.localizedDescription)" }
    }

    private func archivedArtifactURL(_ record: BuildHistoryRecord, index: Int) -> URL? {
        guard let root = record.releaseDirectory,
              let relative = record.archivedArtifacts?.dropFirst(index).first,
              !relative.split(separator: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative)
    }

    private func archiveSummary(_ record: BuildHistoryRecord, status: ReleaseArchiveStatus) -> String {
        let artifactCount = record.archivedArtifacts?.count ?? 0
        let symbolCount = record.archivedSymbolFiles?.count ?? 0
        let size = ByteCountFormatter.string(fromByteCount: record.archivedSizeBytes ?? 0, countStyle: .file)
        return "Archive: \(status.rawValue.capitalized) · \(artifactCount) artifacts · \(symbolCount) symbol files · \(size)"
    }

    private func symbolURLs(_ record: BuildHistoryRecord) -> [URL] {
        guard let root = record.releaseDirectory else { return [] }
        return (record.archivedSymbolFiles ?? []).filter { !$0.split(separator: "/").contains("..") }
            .map { URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent($0) }
    }

    private func exportRelease(_ record: BuildHistoryRecord, contents: ReleaseExportContents) {
        guard !isExportingRelease, let releasePath = record.releaseDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "release-\(record.id.uuidString.prefix(8)).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingRelease = true
        releaseExportTask = Task {
            defer { isExportingRelease = false; releaseExportTask = nil }
            do { try await store.releaseStorage.exportRelease(at: URL(fileURLWithPath: releasePath), destination: destination, contents: contents) }
            catch is CancellationError { storageActionError = "Release export cancelled. The destination was left unchanged." }
            catch { storageActionError = "Release export failed: \(error.localizedDescription)" }
        }
    }

    private func exportReleaseFolder(_ record: BuildHistoryRecord) {
        guard !isExportingRelease, let releasePath = record.releaseDirectory else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export Release Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let name = "release-\(record.id.uuidString.lowercased())"
        isExportingRelease = true
        releaseExportTask = Task {
            defer { isExportingRelease = false; releaseExportTask = nil }
            do { try await store.releaseStorage.exportReleaseFolder(at: URL(fileURLWithPath: releasePath), to: folder.appendingPathComponent(name, isDirectory: true), contents: .complete) }
            catch is CancellationError { storageActionError = "Release export cancelled. The destination was left unchanged." }
            catch { storageActionError = "Release export failed: \(error.localizedDescription)" }
        }
    }
    private func saveLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(project.name)-build.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try logs.write(to: url, atomically: true, encoding: .utf8) } catch { store.error = error.localizedDescription }
    }
}

private struct BuildLogConsole: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 10, height: 9)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let clip = scroll.contentView
        let previousOrigin = clip.bounds.origin
        let wasAtBottom = clip.documentVisibleRect.maxY >= view.bounds.height - 36
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        let source = text as NSString
        var offset = 0
        while offset < source.length {
            let line = source.lineRange(for: NSRange(location: offset, length: 0))
            let value = source.substring(with: line).lowercased()
            let color: NSColor?
            if value.contains("error") || value.contains("failed") { color = .systemRed }
            else if value.contains("warning") || value.contains("deprecated") { color = .systemOrange }
            else { color = nil }
            if let color { styled.addAttribute(.foregroundColor, value: color, range: line) }
            offset = NSMaxRange(line)
        }
        view.textStorage?.setAttributedString(styled)
        if let container = view.textContainer, let manager = view.layoutManager {
            manager.ensureLayout(for: container)
            let contentHeight = manager.usedRect(for: container).height + view.textContainerInset.height * 2
            view.setFrameSize(NSSize(width: clip.bounds.width, height: max(contentHeight, clip.bounds.height)))
        }
        if wasAtBottom {
            view.scrollRangeToVisible(NSRange(location: styled.length, length: 0))
        } else {
            let maxY = max(0, view.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: previousOrigin.x, y: min(previousOrigin.y, maxY)))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
