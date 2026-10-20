import Foundation

struct FlutterRelease: Identifiable, Sendable, Decodable, Equatable {
    var id: String { "\(version)-\(channel)" }
    let version: String
    let channel: String
}
