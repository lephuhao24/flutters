import Foundation
import ZIPFoundation

private final class ExportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

actor ProjectArchiveService {
    func createArchive(manifest: ExportManifest, destination: URL, compression: ExportCompression,
                       replaceExisting: Bool = false,
                       report: @escaping @Sendable (ExportProgress) async -> Void) async throws -> ExportReceipt {
        let flag = ExportCancellationFlag()
        return try await withTaskCancellationHandler {
            try await writeArchive(manifest: manifest, destination: destination, compression: compression,
                                   replaceExisting: replaceExisting, flag: flag, report: report)
        } onCancel: { flag.cancel() }
    }

    private func writeArchive(manifest: ExportManifest, destination: URL, compression: ExportCompression,
                              replaceExisting: Bool, flag: ExportCancellationFlag,
                              report: @escaping @Sendable (ExportProgress) async -> Void) async throws -> ExportReceipt {
        let start = ContinuousClock.now
        let worker = Task.detached(priority: .utility) {
            try await Self.writeSynchronously(manifest: manifest, destination: destination, compression: compression,
                                              replaceExisting: replaceExisting, flag: flag, report: report, start: start)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { flag.cancel(); worker.cancel() }
    }

    private nonisolated static func writeSynchronously(manifest: ExportManifest, destination: URL,
                                                        compression: ExportCompression, replaceExisting: Bool,
                                                        flag: ExportCancellationFlag,
                                                        report: @escaping @Sendable (ExportProgress) async -> Void,
                                                        start: ContinuousClock.Instant) async throws -> ExportReceipt {
        let manager = FileManager.default
        let finalURL = destination.standardizedFileURL
        guard finalURL.pathExtension.lowercased() == "zip" else {
            throw ProjectExportError.destinationUnavailable("Choose a filename ending in .zip.")
        }
        let parent = finalURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              manager.isWritableFile(atPath: parent.path) else {
            throw ProjectExportError.destinationUnavailable("The selected folder does not exist or is not writable.")
        }
        let existingAttributes = try? manager.attributesOfItem(atPath: finalURL.path)
        if let existingAttributes {
            guard existingAttributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  existingAttributes[.type] as? FileAttributeType == .typeRegular else {
                throw ProjectExportError.destinationUnavailable("The destination exists and is not a regular file.")
            }
            if !replaceExisting { throw ProjectExportError.destinationExists(finalURL) }
        } else if manager.fileExists(atPath: finalURL.path) {
            throw ProjectExportError.destinationUnavailable("The existing destination cannot be inspected safely.")
        }
        let tempURL = parent.appendingPathComponent(".fvm-gui-export-\(UUID().uuidString).zip")
        defer { try? manager.removeItem(at: tempURL) }
        guard !manifest.files.isEmpty else { throw ProjectExportError.noFiles }
        var archivePaths = Set<String>()
        for entry in manifest.files where !archivePaths.insert(entry.relativePath).inserted {
            throw ProjectExportError.duplicatePath(entry.relativePath)
        }
        let mode: CompressionMethod = .deflate
        _ = compression // ZIPFoundation exposes Deflate but does not expose a public Deflate-level setting.
        await report(ExportProgress(stage: .compressing, currentPath: nil, filesCompleted: 0,
                                    totalFiles: manifest.files.count, bytesProcessed: 0, totalBytes: manifest.totalBytes))
        do {
            let archive = try Archive(url: tempURL, accessMode: .create)
            var completedBytes: Int64 = 0
            for (index, entry) in manifest.files.enumerated() {
                if flag.isCancelled || Task.isCancelled { throw CancellationError() }
                try Self.validate(entry, root: manifest.projectRoot)
                let fileProgress = Progress(totalUnitCount: max(1, entry.size))
                fileProgress.isCancellable = true
                let baseBytes = completedBytes
                let reporter = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        if flag.isCancelled { fileProgress.cancel(); return }
                        let processed = baseBytes + fileProgress.completedUnitCount
                        await report(ExportProgress(stage: .compressing, currentPath: entry.relativePath,
                                                    filesCompleted: index, totalFiles: manifest.files.count,
                                                    bytesProcessed: min(processed, manifest.totalBytes), totalBytes: manifest.totalBytes))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                do {
                    try archive.addEntry(with: entry.relativePath, fileURL: entry.sourceURL,
                                         compressionMethod: mode, bufferSize: 1_048_576, progress: fileProgress)
                } catch {
                    reporter.cancel()
                    await reporter.value
                    if flag.isCancelled || Task.isCancelled { throw CancellationError() }
                    throw error
                }
                reporter.cancel()
                await reporter.value
                if flag.isCancelled || Task.isCancelled { throw CancellationError() }
                completedBytes += entry.size
                await report(ExportProgress(stage: .compressing, currentPath: entry.relativePath,
                                            filesCompleted: index + 1, totalFiles: manifest.files.count,
                                            bytesProcessed: completedBytes, totalBytes: manifest.totalBytes))
            }
            if flag.isCancelled || Task.isCancelled { throw CancellationError() }
            await report(ExportProgress(stage: .finalizing, currentPath: nil, filesCompleted: manifest.files.count,
                                        totalFiles: manifest.files.count, bytesProcessed: manifest.totalBytes,
                                        totalBytes: manifest.totalBytes))
            let verify = try Archive(url: tempURL, accessMode: .read)
            let expected = Set(manifest.files.map(\.relativePath))
            let actual = Set(verify.map(\.path))
            guard expected == actual else { throw ProjectExportError.archiveVerificationFailed }
            if flag.isCancelled || Task.isCancelled { throw CancellationError() }
            if existingAttributes != nil {
                guard replaceExisting else { throw ProjectExportError.destinationExists(finalURL) }
                _ = try manager.replaceItemAt(finalURL, withItemAt: tempURL, backupItemName: nil, options: [])
            } else {
                try manager.moveItem(at: tempURL, to: finalURL)
            }
            let attributes = try manager.attributesOfItem(atPath: finalURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let receipt = ExportReceipt(destination: finalURL, archiveBytes: actualSize,
                                        uncompressedBytes: manifest.totalBytes, duration: start.duration(to: .now))
            await report(ExportProgress(stage: .completed, currentPath: nil, filesCompleted: manifest.files.count,
                                        totalFiles: manifest.files.count, bytesProcessed: manifest.totalBytes,
                                        totalBytes: manifest.totalBytes))
            return receipt
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private nonisolated static func validate(_ entry: ExportFileEntry, root: URL) throws {
        let components = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.relativePath.hasPrefix("/"), !entry.relativePath.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
              entry.sourceURL.standardizedFileURL.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
            throw ProjectExportError.unsafePath(entry.relativePath)
        }
        var current = root
        for component in components {
            current.appendPathComponent(String(component))
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ProjectExportError.unsafePath(entry.relativePath)
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: entry.sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let modified = attrs[.modificationDate] as? Date
        let device = attrs[.systemNumber].map(String.init(describing:))
        let inode = attrs[.systemFileNumber].map(String.init(describing:))
        let identifier: String? = if let device, let inode { device + ":" + inode } else { nil }
        guard size == entry.size, modified == entry.modifiedAt,
              entry.fileIdentifier == nil || entry.fileIdentifier == identifier,
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              (attrs[.type] as? FileAttributeType) != .typeSymbolicLink else {
            throw ProjectExportError.fileChanged(entry.relativePath)
        }
    }
}
