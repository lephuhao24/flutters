import Foundation

struct FlutterSDK: Identifiable, Sendable, Decodable, Equatable {
    var id: String { name }
    let name: String
    let type: String?
    let directory: String
    let flutterSdkVersion: String?
    let isSetup: Bool
    var isGlobal = false
    var channel: String? { ["stable", "beta", "dev", "master", "main"].contains(name) ? name : nil }
    enum CodingKeys: String, CodingKey { case name, type, directory, flutterSdkVersion, isSetup }
}
