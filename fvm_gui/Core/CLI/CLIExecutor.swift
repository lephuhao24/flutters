import Foundation
import Darwin

protocol CLIExecuting: Sendable {
    func run(executable: URL, arguments: [String], directory: URL?, timeout: Duration?, output: OutputHandler?) async throws -> CLIResult
}

/// Owns each Process on one actor. Pipe readers never run on the main actor.
actor CLIExecutor: CLIExecuting {
    private let processEnvironment: [String: String]

    /// Overrides are merged after GUI PATH defaults. Pass an explicit base for hermetic tests.
    init(environment base: [String: String] = ProcessInfo.processInfo.environment,
         overrides: [String: String] = [:]) {
        processEnvironment = Self.environment(base).merging(overrides) { _, override in override }
    }

    static func environment(_ original: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = original
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.pub-cache/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = ((original["PATH"] ?? "").components(separatedBy: ":") + paths).filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        env["CI"] = "true"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    func run(executable: URL, arguments: [String], directory: URL? = nil, timeout: Duration? = .seconds(30), output: OutputHandler? = nil) async throws -> CLIResult {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CLIError.executableUnavailable(executable) }
        let process = Process()
        let (termination, completion) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { terminated in
            completion.yield(terminated.terminationStatus)
            completion.finish()
        }
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = processEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            completion.finish()
            throw CLIError.launchFailed(executable, reason: error.localizedDescription)
        }
        // Independent of caller cancellation: cleanup must await the actual exit.
        let exitTask = Task.detached {
            for await code in termination { return code }
            return Int32(-1)
        }
        // A private group lets cancellation include git/dart/flutter children.
        let grouped = getpgid(process.processIdentifier) == process.processIdentifier || setpgid(process.processIdentifier, process.processIdentifier) == 0
        let outTask = Task.detached { await Self.read(stdout.fileHandleForReading, error: false, output: output) }
        let errTask = Task.detached { await Self.read(stderr.fileHandleForReading, error: true, output: output) }
        let clock = ContinuousClock()
        let started = clock.now
        var cancelled = false, timedOut = false
        while process.isRunning {
            if Task.isCancelled || timeout.map({ clock.now - started >= $0 }) == true {
                cancelled = Task.isCancelled
                timedOut = !cancelled
                Self.stop(process, grouped: grouped, signal: SIGTERM)
                await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
                Self.stop(process, grouped: grouped, signal: SIGKILL)
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        // Kill any remaining children holding the pipes after their parent exits.
        if grouped && kill(-process.processIdentifier, 0) == 0 {
            kill(-process.processIdentifier, SIGTERM)
            // Cancellation must not skip the grace period or leave inherited pipes open.
            await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
            kill(-process.processIdentifier, SIGKILL)
        }
        let out = await outTask.value
        let err = await errTask.value
        let exitCode = await exitTask.value
        if cancelled || Task.isCancelled { throw CancellationError() }
        if timedOut { throw CLIError.timedOut(executable, timeout: timeout ?? .zero) }
        return CLIResult(exitCode: exitCode, stdout: out, stderr: err)
    }

    private static func stop(_ process: Process, grouped: Bool, signal: Int32) {
        if grouped { kill(-process.processIdentifier, signal) }
        else if process.isRunning { kill(process.processIdentifier, signal) }
    }

    private static func read(_ handle: FileHandle, error: Bool, output: OutputHandler?) async -> String {
        var all = Data(), pending = Data()
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            all.append(data)
            pending.append(data)
            // Retain only an incomplete UTF-8 suffix, streaming even without newlines.
            let bytes = Array(pending)
            var boundary = bytes.count
            if !bytes.isEmpty {
                var lead = bytes.count - 1
                while lead > 0 && bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
                let first = bytes[lead]
                let expected = first & 0xF8 == 0xF0 ? 4 : first & 0xF0 == 0xE0 ? 3 : first & 0xE0 == 0xC0 ? 2 : 1
                if bytes.count - lead < expected { boundary = lead }
            }
            if boundary > 0 {
                let chunk = Data(pending.prefix(boundary))
                pending = Data(pending.dropFirst(boundary))
                await output?(CLIOutput(text: String(decoding: chunk, as: UTF8.self), isError: error))
            }
        }
        if !pending.isEmpty { await output?(CLIOutput(text: String(decoding: pending, as: UTF8.self), isError: error)) }
        try? handle.close()
        return String(decoding: all, as: UTF8.self)
    }
}
