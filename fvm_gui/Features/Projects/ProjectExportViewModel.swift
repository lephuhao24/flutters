import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class ProjectExportViewModel {
    let project: FlutterProject
    let service: ProjectExportService
    var options = ExportOptions()
    var destination: URL?
    var manifest: ExportManifest?
    var progress = ExportProgress(stage: .preparing, currentPath: nil, filesCompleted: 0, totalFiles: 0, bytesProcessed: 0, totalBytes: 0)
    var isPreparing = false
    var isExporting = false
    var error: String?
    var receipt: ExportReceipt?
    var searchText = ""
    var overwriteConfirmation = false
    var previewRevision = 0
    private var exportStartedAt: ContinuousClock.Instant?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let approvedDirectories: [ApprovedScanDirectory]
    private let projectBookmarks: [String: Data]

    init(project: FlutterProject, service: ProjectExportService, defaults: UserDefaults = .standard,
         approvedDirectories: [ApprovedScanDirectory] = [], projectBookmarks: [String: Data] = [:]) {
        self.project = project
        self.service = service
        self.defaults = defaults
        self.approvedDirectories = approvedDirectories
        self.projectBookmarks = projectBookmarks
        if let data = defaults.data(forKey: "projectExportDirectoryBookmark"),
           let last = Self.resolveBookmark(data) {
            destination = last.appendingPathComponent("\(project.name).zip")
        } else if let path = defaults.string(forKey: "projectExportDirectory"), FileManager.default.fileExists(atPath: path) {
            destination = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("\(project.name).zip")
        }
    }

    var filteredFiles: [ExportFileEntry] {
        guard let manifest, !searchText.isEmpty else { return manifest?.files ?? [] }
        return manifest.files.filter { $0.relativePath.localizedCaseInsensitiveContains(searchText) }
    }

    var elapsed: Duration? { exportStartedAt.map { $0.duration(to: .now) } }

    func browse() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = destination?.lastPathComponent ?? "\(project.name).zip"
        panel.directoryURL = destination?.deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.message = "Choose where to save the project archive."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.setDestination(url) }
        }
    }

    func setDestination(_ url: URL) {
        var output = url
        if output.pathExtension.lowercased() != "zip" { output.appendPathExtension("zip") }
        destination = output
        manifest = nil
        receipt = nil
        error = nil
        progress.stage = .preparing
    }

    func buildPreview() {
        guard !isPreparing, !isExporting else { return }
        previewTask?.cancel()
        isPreparing = true
        error = nil
        progress = ExportProgress(stage: .scanning, currentPath: nil, filesCompleted: 0, totalFiles: 0, bytesProcessed: 0, totalBytes: 0)
        previewTask = Task { [weak self, service, project] in
            guard let self else { return }
            let root = self.projectAccessURL
            let hasScope = root.startAccessingSecurityScopedResource()
            defer { if hasScope { root.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await service.preview(project: project, options: self.options, destination: self.destination) { value in
                    await self.update(value)
                }
                try Task.checkCancellation()
                self.manifest = result
                self.previewRevision += 1
                self.progress = ExportProgress(stage: .preparing, currentPath: nil, filesCompleted: result.files.count,
                                               totalFiles: result.files.count, bytesProcessed: result.totalBytes, totalBytes: result.totalBytes)
            } catch is CancellationError {
                self.progress.stage = .cancelled
            } catch { self.error = error.localizedDescription; self.progress.stage = .failed }
            self.isPreparing = false
        }
    }

    func cancelPreview() { previewTask?.cancel() }

    func requestExport() {
        guard !isPreparing, !isExporting else { return }
        if destination == nil {
            browse()
            return
        }
        guard manifest != nil else { buildPreview(); return }
        guard let destination else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            overwriteConfirmation = true
            return
        }
        startExport(replaceExisting: false)
    }

    func confirmReplace() { overwriteConfirmation = false; startExport(replaceExisting: true) }

    func startExport(replaceExisting: Bool) {
        guard !isExporting, manifest != nil, let destination else { return }
        isExporting = true
        exportStartedAt = .now
        error = nil
        receipt = nil
        exportTask = Task { [weak self, service] in
            guard let self else { return }
            let root = self.projectAccessURL
            let rootScope = root.startAccessingSecurityScopedResource()
            let destinationParent = destination.deletingLastPathComponent()
            let outputScope = destinationParent.startAccessingSecurityScopedResource()
            defer {
                if rootScope { root.stopAccessingSecurityScopedResource() }
                if outputScope { destinationParent.stopAccessingSecurityScopedResource() }
            }
            do {
                guard let approved = self.manifest else { throw ProjectExportError.noFiles }
                let result = try await service.createArchive(manifest: approved, destination: destination,
                                                              compression: self.options.compression,
                                                              replaceExisting: replaceExisting) { value in
                    await self.update(value)
                }
                self.receipt = result
                self.progress.stage = .completed
                self.persistSuccessfulDirectory(destinationParent)
            } catch is CancellationError { self.progress.stage = .cancelled }
            catch {
                if let exportError = error as? ProjectExportError, case .fileChanged = exportError { self.manifest = nil }
                self.error = error.localizedDescription
                self.progress.stage = .failed
            }
            self.isExporting = false
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func update(_ value: ExportProgress) { progress = value }

    private var projectAccessURL: URL {
        let projectPath = URL(fileURLWithPath: project.path).standardizedFileURL.path
        let canonicalProjectPath = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path
        if let bookmark = projectBookmarks[canonicalProjectPath], let scopedURL = Self.resolveBookmark(bookmark) {
            return scopedURL
        }
        let record = approvedDirectories
            .filter { projectPath == $0.path || projectPath.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
        guard let record, let data = record.bookmark else { return URL(fileURLWithPath: project.path) }
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                         bookmarkDataIsStale: &stale)) ?? URL(fileURLWithPath: project.path)
    }

    private func persistSuccessfulDirectory(_ directory: URL) {
        defaults.set(directory.path, forKey: "projectExportDirectory")
        if let bookmark = try? directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: "projectExportDirectoryBookmark")
        }
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }
}
