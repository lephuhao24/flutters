import Foundation

enum ExportCompression: String, CaseIterable, Identifiable, Sendable {
    case deflate = "Deflate"
    var id: String { rawValue }
    var description: String { "ZIPFoundation Deflate (default level)" }
}

struct ExportOptions: Sendable, Equatable {
    var respectGitIgnore = true
    var excludeGitDirectory = true
    var excludeFlutterCaches = true
    var includeUntrackedFiles = true
    var compression: ExportCompression = .deflate
    var excludedSensitivePaths = Set<String>()
}

struct ExportFileEntry: Sendable, Equatable, Identifiable {
    let relativePath: String
    let sourceURL: URL
    let size: Int64
    let modifiedAt: Date
    let fileIdentifier: String?
    var id: String { relativePath }
}

struct ExportManifest: Sendable, Equatable {
    let projectRoot: URL
    let files: [ExportFileEntry]
    let totalBytes: Int64
    let excludedFileCount: Int
    let sensitivePaths: [String]
    let warnings: [String]
    let usedGitIgnore: Bool
}

enum ExportStage: String, Sendable, Equatable {
    case preparing = "Preparing"
    case scanning = "Scanning"
    case buildingManifest = "Building Manifest"
    case compressing = "Compressing"
    case finalizing = "Finalizing"
    case completed = "Completed"
    case cancelled = "Cancelled"
    case failed = "Failed"
}

struct ExportProgress: Sendable, Equatable {
    var stage: ExportStage
    var currentPath: String?
    var filesCompleted: Int
    var totalFiles: Int
    var bytesProcessed: Int64
    var totalBytes: Int64
    var fraction: Double? {
        if stage == .completed { return 1 }
        if stage != .compressing { return nil }
        if totalBytes > 0 { return min(0.99, Double(bytesProcessed) / Double(totalBytes)) }
        guard totalFiles > 0 else { return nil }
        return min(0.99, Double(filesCompleted) / Double(totalFiles))
    }
}

struct ExportReceipt: Sendable, Equatable {
    let destination: URL
    let archiveBytes: Int64
    let uncompressedBytes: Int64
    let duration: Duration
    var compressionRatio: Double? {
        guard uncompressedBytes > 0 else { return nil }
        return Double(archiveBytes) / Double(uncompressedBytes)
    }
}

enum ProjectExportError: LocalizedError {
    case invalidProjectRoot
    case noFiles
    case unsafePath(String)
    case fileChanged(String)
    case duplicatePath(String)
    case destinationExists(URL)
    case destinationUnavailable(String)
    case archiveVerificationFailed
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectRoot: "The project folder is unavailable."
        case .noFiles: "There are no files to export with the current options."
        case let .unsafePath(path): "A file has an unsafe archive path and was not exported: \(path)"
        case let .fileChanged(path): "\(path) changed or disappeared after preview. Refresh the preview and try again."
        case let .duplicatePath(path): "The archive manifest contains a duplicate path: \(path)"
        case let .destinationExists(url): "A file already exists at \(url.path). Choose another name or confirm replacement."
        case let .destinationUnavailable(reason): "The export destination is unavailable: \(reason)"
        case .archiveVerificationFailed: "The completed ZIP archive did not contain the expected files."
        case let .gitFailed(reason): "Git could not list project files: \(reason)"
        }
    }
}
