import Foundation

struct FileSystemEntry: Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

protocol FileSystemOperating: Sendable {
    func exists(_ url: URL) async -> Bool
    func contents(of url: URL) async throws -> [FileSystemEntry]
    func isDirectory(_ url: URL) async -> Bool
    func isSymbolicLink(_ url: URL) async -> Bool
    func read(_ url: URL) async throws -> Data
    func write(_ data: Data, to url: URL) async throws
    func createDirectory(_ url: URL) async throws
    func remove(_ url: URL) async throws
}

/// Filesystem calls stay off the main actor and serialize writes through this instance.
/// Errors retain their Foundation domain/code and propagate to the caller.
actor LocalFileSystem: FileSystemOperating {
    private let manager = FileManager()
    func exists(_ url: URL) -> Bool { manager.fileExists(atPath: url.path) }
    func contents(of url: URL) throws -> [FileSystemEntry] {
        try Task.checkCancellation()
        return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            .map { child in
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return FileSystemEntry(url: child, isDirectory: values.isDirectory == true, isSymbolicLink: values.isSymbolicLink == true)
            }
    }
    func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return manager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }
    func write(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
    func createDirectory(_ url: URL) throws {
        try Task.checkCancellation()
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove(_ url: URL) throws {
        try Task.checkCancellation()
        try manager.removeItem(at: url)
    }
}
