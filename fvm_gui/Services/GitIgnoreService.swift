import Foundation

struct GitFileListing: Sendable {
    let paths: [String]?
    let warning: String?
}

/// Uses Git's own index and exclude machinery. A nil path list means the directory is not
/// usable as a Git work tree and callers should use the explicitly warned filesystem fallback.
actor GitIgnoreService {
    private let executor: any CLIExecuting
    private let gitURL: URL?

    init(executor: any CLIExecuting = CLIExecutor(), gitURL: URL? = GitIgnoreService.findGit()) {
        self.executor = executor
        self.gitURL = gitURL
    }

    func listFiles(root: URL, includeUntracked: Bool, respectIgnore: Bool = true) async throws -> GitFileListing {
        try Task.checkCancellation()
        guard let gitURL else { return GitFileListing(paths: nil, warning: "Git is unavailable. Full .gitignore rules cannot be guaranteed; using a filesystem scan.") }
        var arguments = ["-C", root.path, "ls-files", "--cached"]
        if includeUntracked {
            arguments.append("--others")
            if respectIgnore { arguments.append("--exclude-standard") }
        }
        arguments.append("-z")
        do {
            let result = try await executor.run(executable: gitURL, arguments: arguments, directory: nil, timeout: .seconds(60), output: nil)
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                return GitFileListing(paths: nil, warning: "This folder is not a readable Git work tree (Git exit \(result.exitCode)); full .gitignore rules cannot be guaranteed. Using a filesystem scan.")
            }
            let paths = result.stdout.utf8.split(separator: 0, omittingEmptySubsequences: true).compactMap { String(bytes: $0, encoding: .utf8) }
            return GitFileListing(paths: paths, warning: nil)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CLIError {
            return GitFileListing(paths: nil, warning: "Git could not enumerate files (\(error.localizedDescription)); full .gitignore rules cannot be guaranteed. Using a filesystem scan.")
        }
    }

    private static func findGit() -> URL? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let search = environmentPath.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in search {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
