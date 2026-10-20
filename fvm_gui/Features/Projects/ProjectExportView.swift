import AppKit
import SwiftUI

struct ProjectExportView: View {
    @State private var model: ProjectExportViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingOverwrite = false

    init(project: FlutterProject, service: ProjectExportService, approvedDirectories: [ApprovedScanDirectory] = [],
         projectBookmarks: [String: Data] = [:]) {
        _model = State(initialValue: ProjectExportViewModel(project: project, service: service,
                                                            approvedDirectories: approvedDirectories,
                                                            projectBookmarks: projectBookmarks))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    destinationSection
                    optionsSection
                    if let manifest = model.manifest { preview(manifest) }
                    if model.isExporting { progressPanel }
                    if let receipt = model.receipt { completedPanel(receipt) }
                    if let error = model.error { errorPanel(error) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Replace existing archive?", isPresented: $model.overwriteConfirmation, titleVisibility: .visible) {
            Button("Replace ZIP", role: .destructive) { model.confirmReplace() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("\(model.destination?.lastPathComponent ?? "The file") already exists. The current archive will be replaced only after a new ZIP is built and verified.") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Export Project as ZIP").font(.title2.weight(.semibold))
                Text(model.project.name).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close").disabled(model.isExporting || model.isPreparing)
        }
        .padding(20)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Destination", systemImage: "folder").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.destination?.lastPathComponent ?? "Choose a ZIP filename").font(.system(.body, design: .monospaced))
                    Text(model.destination?.deletingLastPathComponent().path ?? "No destination selected")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Browse…") { model.browse() }.disabled(model.isPreparing || model.isExporting)
            }
            Text("Git-tracked files are included even when ignored. Untracked files are included unless Git ignores them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Archive Options", systemImage: "slider.horizontal.3").font(.headline)
            Toggle("Respect .gitignore and Git exclude rules", isOn: option(\.respectGitIgnore))
                .disabled(model.isPreparing || model.isExporting)
            Toggle("Exclude the .git directory", isOn: option(\.excludeGitDirectory))
                .disabled(model.isPreparing || model.isExporting)
            Toggle("Exclude Flutter and build caches", isOn: option(\.excludeFlutterCaches))
                .disabled(model.isPreparing || model.isExporting)
            Toggle("Include untracked non-ignored files", isOn: option(\.includeUntrackedFiles))
                .disabled(model.isPreparing || model.isExporting || !model.options.respectGitIgnore)
            HStack {
                Text("Compression")
                Spacer()
                Text(ExportCompression.deflate.description).foregroundStyle(.secondary)
            }.font(.callout)
            Text("ZIPFoundation exposes Deflate using its default level; separate Fast, Balanced, and Maximum levels are not available.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func preview(_ manifest: ExportManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Preview", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button { model.buildPreview() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(model.isPreparing || model.isExporting)
            }
            HStack(spacing: 18) {
                metric("Files", value: manifest.files.count.formatted())
                metric("Uncompressed", value: ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file))
                metric("Excluded", value: manifest.excludedFileCount.formatted())
                Spacer()
                Label(manifest.usedGitIgnore ? "Git rules applied" : "Filesystem fallback", systemImage: manifest.usedGitIgnore ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(manifest.usedGitIgnore ? Color.secondary : Color.orange)
            }
            if !manifest.warnings.isEmpty {
                ForEach(manifest.warnings, id: \.self) { warning in Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            if !manifest.sensitivePaths.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Potentially sensitive files", systemImage: "exclamationmark.shield.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text("Review these filenames before export. File contents are never inspected.").font(.caption).foregroundStyle(.secondary)
                    ForEach(manifest.sensitivePaths, id: \.self) { path in
                        Toggle(isOn: sensitiveOption(path)) { Label(path, systemImage: "lock") }
                            .toggleStyle(.checkbox).font(.system(.caption, design: .monospaced))
                            .disabled(model.isPreparing || model.isExporting)
                    }
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                TextField("Filter files", text: $model.searchText).textFieldStyle(.roundedBorder).frame(maxWidth: 250)
                Text("\(model.filteredFiles.count) shown").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.filteredFiles) { file in
                        HStack(spacing: 8) {
                            Image(systemName: manifest.sensitivePaths.contains(file.relativePath) ? "lock.fill" : "doc")
                                .foregroundStyle(manifest.sensitivePaths.contains(file.relativePath) ? .orange : .secondary)
                            Text(file.relativePath).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }.padding(8)
            }
            .frame(minHeight: 130, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label(model.progress.stage.rawValue, systemImage: "arrow.down.doc").font(.headline); Spacer(); Text("\(model.progress.filesCompleted) / \(model.progress.totalFiles) files").font(.caption).foregroundStyle(.secondary) }
            if let fraction = model.progress.fraction {
                HStack(spacing: 10) {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .trailing)
                }
            }
            else { ProgressView() }
            if let current = model.progress.currentPath { Text(current).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: model.progress.bytesProcessed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.progress.totalBytes, countStyle: .file))")
                Spacer()
                if let elapsed = model.elapsed { Text("Elapsed \(elapsed.formatted(.units(allowed: [.seconds], width: .abbreviated)))") }
                Spacer()
                Button("Cancel Export", role: .cancel) { model.cancelExport() }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func completedPanel(_ receipt: ExportReceipt) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Export Complete", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            Text(receipt.destination.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
                Text("ZIP size: \(ByteCountFormatter.string(fromByteCount: receipt.archiveBytes, countStyle: .file))")
                if let ratio = receipt.compressionRatio { Text("· Compression ratio \(Int(ratio * 100))%") }
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([receipt.destination]) }
                Button("Open ZIP") { NSWorkspace.shared.open(receipt.destination) }
            }.font(.caption)
        }.padding(14).background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorPanel(_ error: String) -> some View {
        HStack(alignment: .top) {
            Label("Export Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.headline)
            Text(error).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Retry") { model.requestExport() }
        }.padding(14).background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            if model.isPreparing { ProgressView(model.progress.stage.rawValue).controlSize(.small); Button("Cancel") { model.cancelPreview() } }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isPreparing || model.isExporting)
            if model.isExporting {
                Button("Cancel Export", role: .cancel) { model.cancelExport() }
            } else {
                Button("Preview") { model.buildPreview() }.disabled(model.isPreparing)
                Button("Export ZIP") { model.requestExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPreparing || model.isExporting || model.manifest?.files.isEmpty == true)
            }
        }.padding(14)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value).font(.headline.monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }
    }

    private func option(_ keyPath: WritableKeyPath<ExportOptions, Bool>) -> Binding<Bool> {
        Binding(get: { model.options[keyPath: keyPath] }, set: {
            model.options[keyPath: keyPath] = $0
            model.manifest = nil
            model.receipt = nil
        })
    }

    private func sensitiveOption(_ path: String) -> Binding<Bool> {
        Binding(get: { !model.options.excludedSensitivePaths.contains(path) }, set: { include in
            if include { model.options.excludedSensitivePaths.remove(path) } else { model.options.excludedSensitivePaths.insert(path) }
            model.manifest = nil
            model.receipt = nil
        })
    }
}
