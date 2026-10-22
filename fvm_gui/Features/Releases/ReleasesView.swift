import SwiftUI

/// Presented on demand from the unified Flutter SDKs screen.
struct InstallSDKView: View {
    @Bindable var container: AppContainer
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var channel = "All"
    @State private var customVersion = ""

    private var channels: [String] { ["All"] + Set(container.releases.map(\.channel)).sorted() }
    private var filtered: [FlutterRelease] {
        container.releases.filter {
            (channel == "All" || $0.channel == channel)
                && (search.isEmpty || $0.version.localizedCaseInsensitiveContains(search))
        }
    }
    private func installed(_ release: FlutterRelease) -> Bool {
        container.sdkModel?.sdks.contains { $0.name == release.version || $0.flutterSdkVersion == release.version } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channel")
                Picker("Channel", selection: $channel) {
                    ForEach(channels, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 150)
                Spacer()
                Button { Task { await container.loadReleases(forceRefresh: true) } } label: {
                    Label("Refresh Catalog", systemImage: "arrow.clockwise")
                }.disabled(container.loadingReleases || container.busy)
            }.padding(.horizontal).padding(.top, 12)

            if container.loadingReleases {
                ProgressView("Fetching Flutter releases…").padding()
            } else if let error = container.releaseError, container.releases.isEmpty {
                ContentUnavailableView("Cannot Load Releases", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { release in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(release.version).font(.headline)
                            Text(release.channel.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if installed(release) {
                            Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else {
                            Button("Install") { beginInstall(release.version) }.disabled(container.busy)
                        }
                    }.padding(.vertical, 5)
                }
            }

            Divider()
            HStack(spacing: 10) {
                TextField("Version or channel (for example 3.47.2 or stable)", text: $customVersion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { beginInstall(customVersion) }
                Button("Install") { beginInstall(customVersion) }
                    .disabled(container.busy || !valid(customVersion))
                    .keyboardShortcut(.defaultAction)
            }.padding()

            if container.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(container.operation.progress?.message ?? "Installing Flutter SDK…")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { container.cancel() }.disabled(container.operation.cancelling)
                }.padding(.horizontal).padding(.bottom, 12)
            } else if let failure = container.operation.failure {
                Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled).padding()
            }
        }
        .searchable(text: $search, prompt: "Search versions")
        .navigationTitle("Install Flutter SDK")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .task { await container.loadReleases() }
    }

    private func valid(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.hasPrefix("-")
    }

    private func beginInstall(_ value: String) {
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard valid(version), !container.busy else { return }
        customVersion = ""
        container.modify(["install", version])
    }
}
