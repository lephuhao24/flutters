import Foundation

struct CLIResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    /// Opt in at service boundaries; discovery can still inspect unsupported-command exits.
    func requireSuccess(command: String) throws {
        guard exitCode == 0 else { throw CLIError.nonzeroExit(command: command, result: self) }
    }
}
struct CLIOutput: Sendable {
    let text: String
    let isError: Bool
}
typealias OutputHandler = @Sendable (CLIOutput) async -> Void
