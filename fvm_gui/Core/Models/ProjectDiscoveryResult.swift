import Foundation

struct ProjectDiscoveryIssue: Identifiable, Sendable, Equatable {
    let id: String
    let message: String
}

struct ProjectDiscoveryResult: Sendable {
    let projects: [FlutterProject]
    let issues: [ProjectDiscoveryIssue]
    let scannedDirectories: Int
}

struct ApprovedScanDirectory: Codable, Sendable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let bookmark: Data?
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    init(url: URL, bookmark: Data? = nil) {
        path = url.standardizedFileURL.path
        self.bookmark = bookmark
    }
}
