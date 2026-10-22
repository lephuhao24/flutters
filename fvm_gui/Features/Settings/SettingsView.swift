import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var container: AppContainer
    @State private var releaseStoragePath = UserDefaults.standard.string(forKey: ReleaseStorageService.customPathKey) ?? ""
    @State private var releaseCount = 0
    @State private var releaseSize: Int64 = 0
    @State private var pendingStorageURL: URL?
    @State private var pendingBookmark: Data?
    @State private var showingStorageChangeOptions = false
    @State private var storageOperation = false
    @State private var storageMessage: String?
    private let releaseStorage = ReleaseStorageService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Dependency Settings").font(.title2)
                menuBarSettings
                launchAtLoginSettings
                releaseStorageSettings
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

    private var releaseStorageSettings: some View {
        let current = effectiveStorageURL
        return VStack(alignment: .leading, spacing: 10) {
            Text("Release Storage").font(.headline)
            LabeledContent("Location", value: current.path).font(.caption)
            LabeledContent("Archived releases", value: "\(releaseCount)")
            LabeledContent("Archive size", value: ByteCountFormatter.string(fromByteCount: releaseSize, countStyle: .file))
            if let capacity = try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                LabeledContent("Available on volume", value: ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))
            }
            Toggle("Archive new release builds by default", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "buildRelease.archiveByDefault") as? Bool ?? true },
                set: { enabled in UserDefaults.standard.set(enabled, forKey: "buildRelease.archiveByDefault") }
            ))
            HStack {
                Button("Change Location…") { chooseStorageLocation() }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([current]) }
                Button("Open Release Archive") { NSWorkspace.shared.open(current) }
            }
            HStack {
                Button("Reset to Default") { resetStorageLocation() }.disabled(releaseStoragePath.isEmpty)
                if storageOperation { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let storageMessage {
                Text(storageMessage).font(.caption).foregroundStyle(storageMessage.localizedCaseInsensitiveContains("could not") ? .red : .secondary).textSelection(.enabled)
            }
            Text("Dart symbol files can reveal obfuscated source mappings. Keep release archives private and backed up securely.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .task { await refreshStorageStatistics() }
        .confirmationDialog("Use the selected release storage location", isPresented: $showingStorageChangeOptions, titleVisibility: .visible) {
            Button("Use for Future Builds") { applyPendingStorageLocation() }
            Button("Move Existing Archives") { Task { await migrateAndApplyStorageLocation() } }
            Button("Cancel", role: .cancel) { pendingStorageURL = nil; pendingBookmark = nil }
        } message: {
            Text("Existing archives will remain in place unless you choose Move Existing Archives. The current archive uses \(ByteCountFormatter.string(fromByteCount: releaseSize, countStyle: .file)).")
        }
    }

    private var effectiveStorageURL: URL {
        if !releaseStoragePath.isEmpty { return URL(fileURLWithPath: releaseStoragePath, isDirectory: true) }
        return (try? ReleaseStorageService.defaultStorageURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("Releases", isDirectory: true)
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Release Storage"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingStorageURL = url
            pendingBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            showingStorageChangeOptions = true
        } catch { storageMessage = "Release storage location could not be authorized: \(error.localizedDescription)" }
    }

    private func applyPendingStorageLocation() {
        guard let url = pendingStorageURL else { return }
        Task {
            do {
                try await releaseStorage.configureStorageLocation(url, bookmark: pendingBookmark)
                releaseStoragePath = url.path
                storageMessage = "New builds will use the selected release storage location. Existing archives were left in place."
                await refreshStorageStatistics()
            } catch { storageMessage = "Release storage location could not be changed: \(error.localizedDescription)" }
            pendingStorageURL = nil
            pendingBookmark = nil
        }
    }

    private func migrateAndApplyStorageLocation() async {
        guard let destination = pendingStorageURL else { return }
        storageOperation = true
        defer { storageOperation = false }
        do {
            let source = effectiveStorageURL
            if releaseSize > 0 {
                try await releaseStorage.migrateArchives(from: source, to: destination)
                container.buildReleaseStore.rewriteReleaseRootPaths(from: source, to: destination)
            }
            try await releaseStorage.configureStorageLocation(destination, bookmark: pendingBookmark)
            releaseStoragePath = destination.path
            storageMessage = "Existing archives were copied, verified, and moved to the new location."
            await refreshStorageStatistics()
        } catch { storageMessage = "Release storage migration could not be completed: \(error.localizedDescription). Original archives remain available." }
        pendingStorageURL = nil
        pendingBookmark = nil
    }

    private func resetStorageLocation() {
        Task {
            await releaseStorage.resetStorageLocation()
            releaseStoragePath = ""
            storageMessage = "The default Application Support location will be used for future builds. Existing custom archives were left in place."
            await refreshStorageStatistics()
        }
    }

    private func refreshStorageStatistics() async {
        do {
            let stats = try await releaseStorage.storageStatistics()
            releaseCount = stats.releaseCount
            releaseSize = stats.sizeBytes
        } catch { storageMessage = "Release storage could not be inspected: \(error.localizedDescription)" }
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
