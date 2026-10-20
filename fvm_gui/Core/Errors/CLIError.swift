import Foundation

/// Cancellation deliberately remains CancellationError, so structured concurrency callers
/// can distinguish it from an operational failure. Nonzero exits remain inspectable results.
enum CLIError: LocalizedError, Sendable {
    case executableUnavailable(URL)
    case launchFailed(URL, reason: String)
    case timedOut(URL, timeout: Duration)
    case nonzeroExit(command: String, result: CLIResult)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable(let url):
            "Executable is missing or not executable: \(url.path). Choose the executable in Settings."
        case .launchFailed(let url, let reason):
            "Cannot launch \(url.lastPathComponent): \(reason)"
        case .timedOut(let url, let timeout):
            "\(url.lastPathComponent) timed out after \(timeout). Check the executable, network, then retry."
        case .nonzeroExit(let command, let result):
            "\(command) failed (\(result.exitCode)).\n\(result.stderr)\n\(result.stdout)"
        }
    }
}
