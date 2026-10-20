import SwiftUI

struct SDKStorageView: View {
    @Bindable var container: AppContainer
    @State private var removing: SDKStorageItem?
    private var model: SDKStorageViewModel { container.storageModel }

    var body: some View {
        VStack(spacing: 0) {
            if let analysis = model.analysis {
                summary(analysis)
                if let issue = analysis.items.first(where: { $0.measurementIssue != nil })?.measurementIssue {
                    Label("Some SDK directories could not be measured. Their space is excluded from totals. \(issue)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
                }
                if analysis.items.isEmpty {
                    ContentUnavailableView("No Installed SDKs", systemImage: "externaldrive", description: Text("Install a Flutter SDK to see its storage usage here."))
                } else {
                    List(model.sortedItems) { item in sdkRow(item) }
                }
            } else if model.status == .running {
                ProgressView("Measuring installed SDKs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView("Storage Could Not Be Measured", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(error))
            } else {
                ContentUnavailableView("No Storage Data", systemImage: "externaldrive", description: Text("Refresh to measure installed Flutter SDKs."))
            }
            if model.status == .running {
                HStack { ProgressView().controlSize(.small); Text(model.progress?.message ?? "Measuring SDKs…").font(.callout).foregroundStyle(.secondary); Spacer(); Button("Cancel Scan") { model.cancel() } }
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .toolbar {
            Picker("Sort", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) { ForEach(SDKStorageSort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            Button { Task { await container.refreshStorage(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.status == .running || container.busy)
        }
        .confirmationDialog("Remove Flutter SDK \(removing?.version ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove SDK", role: .destructive) {
                if let removing { container.removeSDKFromStorage(version: removing.version) }
                removing = nil
            }
            .disabled(removing.flatMap { container.sdkRemovalBlockReason(version: $0.version) } != nil || container.busy)
        } message: {
            if let item = removing {
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.measuredSize), countStyle: .file)
                let referenceWarning = container.sdkReferenceWarning(version: item.version).map { "Important: \($0)" } ?? "No known projects reference this SDK. Other projects may still depend on it."
                let globalWarning = item.isGlobal ? " This is the global SDK and must be changed before removal." : ""
                Text("FVM will remove the SDK and may recover about \(size). \(referenceWarning)\(globalWarning)")
            }
        }
        .task { if model.analysis == nil { await container.refreshStorage() } }
    }

    private func summary(_ analysis: SDKStorageAnalysis) -> some View {
        HStack(spacing: 0) {
            metric("Total SDK Storage", bytes(analysis.totalStorage), symbol: "externaldrive")
            Divider().frame(height: 48)
            metric("Installed SDKs", "\(analysis.installedSDKCount)", symbol: "shippingbox")
            Divider().frame(height: 48)
            metric("Referenced Storage", bytes(analysis.referencedStorage), symbol: "folder", detail: "Known projects")
            Divider().frame(height: 48)
            metric("Potential Cleanup", bytes(analysis.potentialCleanupSpace), symbol: "trash", detail: "No known project references")
            Divider().frame(height: 48)
            metric("Unreferenced", bytes(analysis.storageWithoutKnownReferences), symbol: "questionmark.folder", detail: "Includes global SDKs")
        }
        .padding(.vertical, 14).background(.quaternary.opacity(0.35))
    }

    private func metric(_ title: String, _ value: String, symbol: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
    }

    private func sdkRow(_ item: SDKStorageItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.isCleanupCandidate ? "shippingbox.circle" : "shippingbox.fill")
                .font(.title2).foregroundStyle(item.isCleanupCandidate ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.version).font(.headline)
                    if item.isGlobal { Label("Global", systemImage: "globe").font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.tint.opacity(0.14), in: Capsule()) }
                    if item.isCleanupCandidate { Text("Cleanup candidate").font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.orange.opacity(0.16), in: Capsule()) }
                }
                Text(item.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 16) {
                    Label("\(item.projectReferenceCount) project\(item.projectReferenceCount == 1 ? "" : "s")", systemImage: "folder")
                    if item.registeredProjectReferenceCount > 0 { Text("\(item.registeredProjectReferenceCount) registered") }
                    if item.discoveredProjectReferenceCount > 0 { Text("\(item.discoveredProjectReferenceCount) discovered") }
                    if let issue = item.measurementIssue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(bytes(item.measuredSize)).font(.headline).monospacedDigit()
                Text(item.allocatedSize == nil ? "Logical size" : "On disk").font(.caption).foregroundStyle(.secondary)
                if item.allocatedSize != nil, item.logicalSize != item.measuredSize { Text("\(bytes(item.logicalSize)) logical").font(.caption2).foregroundStyle(.tertiary) }
            }
            Button("Remove…", role: .destructive) { removing = item }
                .disabled(item.measurementIssue != nil || container.sdkRemovalBlockReason(version: item.version) != nil || container.busy)
                .help(container.sdkRemovalBlockReason(version: item.version) ?? "Remove this SDK through FVM")
        }.padding(.vertical, 8)
    }

    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
}
