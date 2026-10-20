import Foundation

/// Records read-only API operations without exposing project pubspec/environment JSON.
struct LoggingCLIExecutor: CLIExecuting {
    let base: any CLIExecuting
    let activity: ActivityStore
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult {
        guard arguments.first == "api", arguments != ["api", "context"], arguments != ["api", "--help"] else {
            return try await base.run(executable: executable, arguments: arguments, directory: directory, timeout: timeout, output: output)
        }
        let id = await activity.begin(command: "fvm " + arguments.joined(separator: " "))
        do {
            let result = try await base.run(executable: executable, arguments: arguments, directory: directory, timeout: timeout, output: output)
            let valid = result.exitCode == 0 && (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) != nil
            await activity.append(valid ? "JSON response received (\(result.stdout.utf8.count) bytes)." : "Invalid JSON or command failure. Check the feature's error message.", id: id)
            await activity.finish(id, status: valid ? .completed : .failed)
            return result
        } catch {
            await activity.finish(id, status: error is CancellationError ? .cancelled : .failed)
            await activity.append(error.localizedDescription, id: id)
            throw error
        }
    }
}
