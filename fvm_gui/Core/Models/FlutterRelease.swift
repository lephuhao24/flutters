import Foundation

struct FlutterRelease: Identifiable, Sendable, Codable, Equatable {
    var id: String { "\(version)-\(channel)" }
    let version: String
    let channel: String
}
