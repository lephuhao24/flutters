import Foundation

struct FVMInstallation: Sendable, Equatable {
    let executable: URL
    let version: String
}
