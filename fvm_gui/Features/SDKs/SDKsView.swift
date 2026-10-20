import SwiftUI

struct SDKsView: View {
    @Bindable var container: AppContainer
    @State private var installing = false
    @State private var version = ""
    @State private var removing: FlutterSDK?
    var body: some View {
        VStack {
            if let model = container.sdkModel {
                if model.loading { ProgressView("Refreshing SDKs…") }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding() }
                if model.sdks.isEmpty && !model.loading {
                    ContentUnavailableView("No Installed SDKs", systemImage: "externaldrive", description: Text("Install a Flutter version to get started."))
                } else {
                    List(model.sdks) { sdk in
                        HStack(spacing: 14) {
                            Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(sdk.name).font(.headline)
                                    if sdk.isGlobal { Text("Global").font(.caption).padding(.horizontal, 6).background(.tint.opacity(0.15), in: Capsule()) }
                                }
                                Text("\(sdk.channel ?? "Channel unknown") · \(sdk.isSetup ? "Ready" : "Setup required")").font(.caption).foregroundStyle(.secondary)
                                Text(sdk.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Menu {
                                Button("Set Global") { container.modify(["global", sdk.name]) }
                                Button("Remove…", role: .destructive) { removing = sdk }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(sdk.name)").disabled(container.busy)
                        }.padding(.vertical, 8)
                        .contextMenu {
                            Button("Set Global") { container.modify(["global", sdk.name]) }.disabled(container.busy)
                            Button("Remove…", role: .destructive) { removing = sdk }.disabled(container.busy)
                        }
                    }
                }
            }
        }
        .toolbar {
            Button { Task { await container.sdkModel?.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(container.busy)
            Button { installing = true } label: { Label("Install", systemImage: "plus") }.disabled(container.busy)
        }
        .sheet(isPresented: $installing) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Install Flutter SDK").font(.title2)
                TextField("Version or channel (e.g. 3.47.2, stable)", text: $version).textFieldStyle(.roundedBorder)
                HStack { Button("Cancel") { installing = false }; Spacer(); Button("Install") { container.modify(["install", version.trimmingCharacters(in: .whitespacesAndNewlines)]); installing = false }.keyboardShortcut(.defaultAction).disabled(version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || version.hasPrefix("-")) }
            }.padding(24).frame(width: 440)
        }
        .alert("Remove \(removing?.name ?? "SDK")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { container.removeSDKFromStorage(version: removing.name) }; removing = nil }
                .disabled(removing.flatMap { container.sdkRemovalBlockReason(version: $0.name) } != nil || container.busy)
        } message: {
            let registered = container.projects.filter { $0.version == removing?.name || $0.configuredVersion == removing?.name }
            let registeredPaths = Set(registered.map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path })
            let discovered = container.projectDiscovery.projects.filter {
                $0.version == removing?.name || $0.configuredVersion == removing?.name
                    ? !registeredPaths.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path)
                    : false
            }
            Text("FVM will remove the cached SDK.\(removing?.isGlobal == true ? " This is the global SDK and must be changed first." : "")\(registered.isEmpty && discovered.isEmpty ? " No known projects reference it, though other projects may still depend on it." : " \(registered.count) registered and \(discovered.count) discovered projects reference it and must be changed first.")")
        }
    }
}
