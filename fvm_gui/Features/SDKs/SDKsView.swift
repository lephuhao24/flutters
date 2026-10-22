import AppKit
import SwiftUI

struct SDKsView: View {
    @Bindable var container: AppContainer
    @State private var search = ""
    @State private var installing = false
    @State private var managingStorage = false
    @State private var inspecting: FlutterSDK?
    @State private var removing: FlutterSDK?

    private var installed: [FlutterSDK] { container.sdkModel?.sdks ?? [] }
    private var filtered: [FlutterSDK] {
        guard !search.isEmpty else { return installed }
        return installed.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || ($0.channel?.localizedCaseInsensitiveContains(search) ?? false)
                || $0.directory.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            storageSummary
            if let model = container.sdkModel, model.loading, installed.isEmpty {
                ProgressView("Loading installed Flutter SDKs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = container.sdkModel?.error, installed.isEmpty {
                ContentUnavailableView("SDKs Could Not Be Loaded", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if installed.isEmpty {
                ContentUnavailableView("No Installed SDKs", systemImage: "externaldrive", description: Text("Install a Flutter version to get started."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { sdk in sdkRow(sdk) }
            }
        }
        .searchable(text: $search, prompt: "Search installed SDKs")
        .toolbar {
            Button { Task { await container.refreshSDKInformation() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(container.busy || container.detecting)
            Button { managingStorage = true } label: { Label("Storage", systemImage: "externaldrive.badge.timemachine") }
            Button { installing = true } label: { Label("Install SDK", systemImage: "plus") }.disabled(container.busy)
        }
        .sheet(isPresented: $installing) {
            NavigationStack { InstallSDKView(container: container) }
                .frame(minWidth: 620, minHeight: 520)
        }
        .sheet(isPresented: $managingStorage) {
            NavigationStack {
                SDKStorageView(container: container)
                    .navigationTitle("SDK Storage")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { managingStorage = false } } }
            }
            .frame(minWidth: 760, minHeight: 540)
        }
        .sheet(item: $inspecting) { sdk in SDKDetailSheet(sdk: sdk, container: container) }
        .confirmationDialog("Remove \(removing?.name ?? "SDK")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let removing { container.removeSDKFromStorage(version: removing.name) }
                removing = nil
            }
            .disabled(removing.flatMap { container.sdkRemovalBlockReason(version: $0.name) } != nil || container.busy)
        } message: {
            if let sdk = removing {
                Text(container.sdkReferenceWarning(version: sdk.name)
                     ?? (sdk.isGlobal ? "This is the global SDK and cannot be removed until another global SDK is selected." : "No known projects reference this SDK. Other projects may still depend on it."))
            }
        }
    }

    private var storageSummary: some View {
        HStack(spacing: 14) {
            Label("\(installed.count) installed", systemImage: "shippingbox")
            if let analysis = container.storageModel.analysis {
                Label(ByteCountFormatter.string(fromByteCount: Int64(clamping: analysis.totalStorage), countStyle: .file), systemImage: "externaldrive")
            } else if container.storageModel.status == .running {
                ProgressView().controlSize(.small)
                Text("Measuring SDK storage…").foregroundStyle(.secondary)
            } else {
                Text("Usage shown in Storage").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Available versions…") { installing = true }.buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.quaternary.opacity(0.35))
    }

    private func sdkRow(_ sdk: FlutterSDK) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(sdk.name).font(.headline)
                    if sdk.isGlobal { badge("Global", symbol: "globe") }
                    if !sdk.isSetup { badge("Setup required", symbol: "wrench", color: .orange) }
                }
                Text("\(sdk.channel ?? sdk.type?.capitalized ?? "Release") · \(sdk.isSetup ? "Ready" : "Setup required")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(sdk.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let item = container.storageModel.analysis?.items.first(where: { $0.version == sdk.name }) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.measuredSize), countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Menu {
                Button("Details…") { inspecting = sdk }
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sdk.directory) }
                Button("Copy SDK Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sdk.directory, forType: .string) }
                Divider()
                Button("Set Global") { container.setGlobalSDK(sdk.name) }.disabled(sdk.isGlobal || container.busy)
                Button("Remove…", role: .destructive) { removing = sdk }
                    .disabled(container.sdkRemovalBlockReason(version: sdk.name) != nil || container.busy)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(sdk.name)")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { inspecting = sdk }
        .contextMenu {
            Button("Details…") { inspecting = sdk }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sdk.directory) }
            Button("Copy SDK Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sdk.directory, forType: .string) }
            Button("Set Global") { container.setGlobalSDK(sdk.name) }.disabled(sdk.isGlobal || container.busy)
            Button("Remove…", role: .destructive) { removing = sdk }.disabled(container.sdkRemovalBlockReason(version: sdk.name) != nil || container.busy)
        }
    }

    private func badge(_ title: String, symbol: String, color: Color = .accentColor) -> some View {
        Label(title, systemImage: symbol).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

private struct SDKDetailSheet: View {
    let sdk: FlutterSDK
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss
    private var storage: SDKStorageItem? { container.storageModel.analysis?.items.first { $0.version == sdk.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(sdk.name, systemImage: "shippingbox.fill").font(.title2)
            LabeledContent("Status", value: sdk.isSetup ? "Ready" : "Setup required")
            LabeledContent("Channel", value: sdk.channel ?? sdk.type?.capitalized ?? "Unknown")
            LabeledContent("Global", value: sdk.isGlobal ? "Yes" : "No")
            LabeledContent("Flutter version", value: sdk.flutterSdkVersion ?? "Unknown")
            LabeledContent("Disk usage", value: storage.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.measuredSize), countStyle: .file) } ?? "Not measured")
            LabeledContent("Known project references", value: storage.map { "\($0.projectReferenceCount) (\($0.registeredProjectReferenceCount) registered, \($0.discoveredProjectReferenceCount) discovered)" } ?? "Not measured")
            LabeledContent("SDK location", value: sdk.directory)
                .textSelection(.enabled)
            Spacer()
            HStack {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: sdk.directory) }
                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sdk.directory, forType: .string) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 520, minHeight: 360)
    }
}
