import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable

    var title: String {
        switch self {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .requiresApproval: "Needs approval"
        case .unavailable: "Unavailable"
        }
    }
}

@MainActor protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }
    var errorMessage: String? { get }
    func refreshStatus()
    func setEnabled(_ enabled: Bool) throws
}

@MainActor @Observable final class LaunchAtLoginService: LaunchAtLoginManaging {
    private let appService: SMAppService
    private(set) var status: LaunchAtLoginStatus = .disabled
    private(set) var errorMessage: String?

    init(appService: SMAppService = .mainApp) {
        self.appService = appService
        refreshStatus()
    }

    func refreshStatus() {
        switch appService.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notRegistered: status = .disabled
        case .notFound: status = .unavailable
        @unknown default: status = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        errorMessage = nil
        do {
            if enabled { try appService.register() }
            else { try appService.unregister() }
            refreshStatus()
        } catch {
            refreshStatus()
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
