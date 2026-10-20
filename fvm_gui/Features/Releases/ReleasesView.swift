import SwiftUI

struct ReleasesView: View {
    @Bindable var container: AppContainer
    @State private var search = ""
    @State private var channel = "All"
    private var channels: [String] { ["All"] + Set(container.releases.map(\.channel)).sorted() }
    private var filtered: [FlutterRelease] {
        container.releases.filter { (channel == "All" || $0.channel == channel) && (search.isEmpty || $0.version.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Channel"); Picker("Channel", selection: $channel) { ForEach(channels, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 140); Spacer() }.padding()
            if container.loadingReleases { ProgressView("Fetching Flutter releases…").padding() }
            if let error = container.releaseError { ContentUnavailableView("Cannot Load Releases", systemImage: "wifi.exclamationmark", description: Text(error)) }
            else if filtered.isEmpty && !container.loadingReleases { ContentUnavailableView.search(text: search) }
            else {
                List(filtered) { release in
                    HStack {
                        VStack(alignment: .leading) { Text(release.version).font(.headline); Text(release.channel.capitalized).foregroundStyle(.secondary) }
                        Spacer()
                        if container.sdkModel?.sdks.contains(where: { $0.name == release.version || $0.flutterSdkVersion == release.version }) == true {
                            Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else { Button("Install") { container.modify(["install", release.version]) }.disabled(container.busy) }
                    }.padding(.vertical, 6)
                }
            }
        }
        .searchable(text: $search, prompt: "Search versions")
        .toolbar { Button { Task { await container.loadReleases() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(container.loadingReleases) }
        .task { if container.releases.isEmpty { await container.loadReleases() } }
    }
}
