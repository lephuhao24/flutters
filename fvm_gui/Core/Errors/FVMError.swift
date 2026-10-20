import Foundation

enum FVMError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}
