import Foundation

enum FlutterProjectType: String, Codable, Sendable {
    case flutterApp
    case flutterPackage
    case flutterPlugin
    case dartPackage

    var displayName: String {
        switch self {
        case .flutterApp: "Flutter App"
        case .flutterPackage: "Flutter Package"
        case .flutterPlugin: "Flutter Plugin"
        case .dartPackage: "Dart Package"
        }
    }
}

struct FlutterProject: Identifiable, Codable, Sendable, Equatable {
    var id: String { path }
    let path: String
    var name: String
    var version: String?
    var configurationSource: String?
    var issue: String?
    var type: FlutterProjectType
    var configuredVersion: String?
    var dartSDKConstraint: String?
    var flutterSDKConstraint: String?
    var platforms: [String]
    var effectiveVersion: String? { version ?? configuredVersion }

    init(path: String, name: String, version: String? = nil, configurationSource: String? = nil,
         issue: String? = nil, type: FlutterProjectType = .flutterApp, configuredVersion: String? = nil,
         dartSDKConstraint: String? = nil, flutterSDKConstraint: String? = nil, platforms: [String] = []) {
        self.path = path
        self.name = name
        self.version = version
        self.configurationSource = configurationSource
        self.issue = issue
        self.type = type
        self.configuredVersion = configuredVersion
        self.dartSDKConstraint = dartSDKConstraint
        self.flutterSDKConstraint = flutterSDKConstraint
        self.platforms = platforms
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, version, configurationSource, issue, type, configuredVersion, dartSDKConstraint, flutterSDKConstraint, platforms
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        configurationSource = try values.decodeIfPresent(String.self, forKey: .configurationSource)
        issue = try values.decodeIfPresent(String.self, forKey: .issue)
        type = try values.decodeIfPresent(FlutterProjectType.self, forKey: .type) ?? .flutterApp
        configuredVersion = try values.decodeIfPresent(String.self, forKey: .configuredVersion)
        dartSDKConstraint = try values.decodeIfPresent(String.self, forKey: .dartSDKConstraint)
        flutterSDKConstraint = try values.decodeIfPresent(String.self, forKey: .flutterSDKConstraint)
        platforms = try values.decodeIfPresent([String].self, forKey: .platforms) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(version, forKey: .version)
        try values.encodeIfPresent(configurationSource, forKey: .configurationSource)
        try values.encodeIfPresent(issue, forKey: .issue)
        try values.encode(type, forKey: .type)
        try values.encodeIfPresent(configuredVersion, forKey: .configuredVersion)
        try values.encodeIfPresent(dartSDKConstraint, forKey: .dartSDKConstraint)
        try values.encodeIfPresent(flutterSDKConstraint, forKey: .flutterSDKConstraint)
        try values.encode(platforms, forKey: .platforms)
    }
}
