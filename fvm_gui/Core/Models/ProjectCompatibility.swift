import Foundation

enum ProjectCompatibilityStatus: String, Sendable, Codable {
    case compatible
    case incompatible
    case sdkMissing
    case unknown
    case unableToEvaluate

    var title: String {
        switch self {
        case .compatible: "Compatible"
        case .incompatible: "Incompatible"
        case .sdkMissing: "SDK Missing"
        case .unknown: "Unknown"
        case .unableToEvaluate: "Unable to Evaluate"
        }
    }
}

struct FlutterSDKMetadata: Sendable, Equatable {
    let sdkName: String
    let directory: String
    let flutterVersion: String?
    let dartSDKVersion: String?
    let isInstalled: Bool
    let isSetup: Bool
    let fingerprint: String
    let issue: String?
}

struct ProjectCompatibility: Sendable, Equatable {
    let projectName: String
    let projectPath: String
    let configurationSource: String?
    let configuredFlutterVersion: String?
    let effectiveFlutterVersion: String?
    let selectedFlutterSDK: String?
    let selectedFlutterVersion: String?
    let bundledDartSDKVersion: String?
    let requiredDartConstraint: String?
    let requiredFlutterConstraint: String?
    let status: ProjectCompatibilityStatus
    let explanation: String
    let recommendedAction: String

    var cacheKey: String {
        [projectPath, configurationSource ?? "", configuredFlutterVersion ?? "", effectiveFlutterVersion ?? "", selectedFlutterSDK ?? "",
         selectedFlutterVersion ?? "", bundledDartSDKVersion ?? "", requiredDartConstraint ?? "", requiredFlutterConstraint ?? "", status.rawValue]
            .joined(separator: "\u{1f}")
    }
}
