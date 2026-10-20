import Foundation

enum FlutterDiagnosticStatus: String, Sendable, Codable {
    case passed
    case warning
    case failed
    case unknown

    var title: String {
        switch self {
        case .passed: "Passed"
        case .warning: "Warning"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }
}

struct FlutterDoctorSuggestedAction: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let instructions: String
    let documentationURL: String?
}

struct FlutterDoctorCategory: Sendable, Equatable, Identifiable {
    let identifier: String
    let name: String
    let status: FlutterDiagnosticStatus
    let diagnosticMessages: [String]
    let suggestedActions: [FlutterDoctorSuggestedAction]
    let rawOutput: String

    var id: String { identifier }
}

struct FlutterDoctorReport: Sendable, Equatable, Identifiable {
    let id: UUID
    let sdkName: String?
    let flutterVersion: String?
    let sdkPath: String?
    let projectName: String?
    let projectPath: String?
    let checkedAt: Date
    let executionStatus: OperationStatus
    let exitCode: Int32?
    let duration: Duration
    let overallStatus: FlutterDiagnosticStatus
    let categories: [FlutterDoctorCategory]
    let rawOutput: String
    let message: String?

    init(id: UUID = UUID(), sdkName: String?, flutterVersion: String?, sdkPath: String?,
         projectName: String?, projectPath: String?, checkedAt: Date = Date(),
         executionStatus: OperationStatus, exitCode: Int32?, duration: Duration,
         overallStatus: FlutterDiagnosticStatus, categories: [FlutterDoctorCategory],
         rawOutput: String, message: String? = nil) {
        self.id = id
        self.sdkName = sdkName
        self.flutterVersion = flutterVersion
        self.sdkPath = sdkPath
        self.projectName = projectName
        self.projectPath = projectPath
        self.checkedAt = checkedAt
        self.executionStatus = executionStatus
        self.exitCode = exitCode
        self.duration = duration
        self.overallStatus = overallStatus
        self.categories = categories
        self.rawOutput = rawOutput
        self.message = message
    }
}
