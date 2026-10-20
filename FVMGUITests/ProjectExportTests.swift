import Foundation
import XCTest
import ZIPFoundation
@testable import fvm_gui

final class ProjectExportTests: XCTestCase {
    func testDefaultsAndDeflateDisclosure() {
        let options = ExportOptions()
        XCTAssertTrue(options.respectGitIgnore)
        XCTAssertTrue(options.excludeGitDirectory)
        XCTAssertTrue(options.excludeFlutterCaches)
        XCTAssertTrue(options.includeUntrackedFiles)
        XCTAssertEqual(options.compression, .deflate)
        XCTAssertTrue(ExportCompression.deflate.description.contains("default level"))
    }

    func testProgressNeverReportsCompleteBeforeArchiveFinalization() {
        let compressing = ExportProgress(stage: .compressing, currentPath: "file", filesCompleted: 1,
                                        totalFiles: 1, bytesProcessed: 100, totalBytes: 100)
        let finalizing = ExportProgress(stage: .finalizing, currentPath: nil, filesCompleted: 1,
                                        totalFiles: 1, bytesProcessed: 100, totalBytes: 100)
        let complete = ExportProgress(stage: .completed, currentPath: nil, filesCompleted: 1,
                                      totalFiles: 1, bytesProcessed: 100, totalBytes: 100)
        XCTAssertEqual(compressing.fraction, 0.99)
        XCTAssertNil(finalizing.fraction)
        XCTAssertEqual(complete.fraction, 1)
    }

    func testGitIgnoreTrackedUntrackedNestedAndNegation() async throws {
        guard let git = findGit() else { throw XCTSkip("Git is unavailable on this machine") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try gitRun(git, root, ["init", "-q"])
        try write("tracked.txt", into: root, contents: "tracked")
        try gitRun(git, root, ["add", "tracked.txt"])
        try write(".gitignore", into: root, contents: "tracked.txt\nignored.txt\n")
        try write("ignored.txt", into: root, contents: "ignore")
        try write("visible.txt", into: root, contents: "visible")
        try write("nested/.gitignore", into: root, contents: "*.secret\n!kept.secret\n")
        try write("nested/hidden.secret", into: root, contents: "hidden")
        try write("nested/kept.secret", into: root, contents: "kept")
        let project = projectAt(root)
        let manifest = try await ProjectExportService().preview(project: project, options: ExportOptions(), destination: nil)
        let paths = Set(manifest.files.map(\.relativePath))
        XCTAssertTrue(manifest.usedGitIgnore)
        XCTAssertTrue(paths.contains("tracked.txt"), "tracked files remain included even when later ignored")
        XCTAssertTrue(paths.contains("visible.txt"))
        XCTAssertTrue(paths.contains("nested/kept.secret"))
        XCTAssertFalse(paths.contains("ignored.txt"))
        XCTAssertFalse(paths.contains("nested/hidden.secret"))
    }

    func testTrackedOnlyModeOmitsUntrackedFiles() async throws {
        guard let git = findGit() else { throw XCTSkip("Git is unavailable on this machine") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try gitRun(git, root, ["init", "-q"])
        try write("tracked.txt", into: root, contents: "tracked")
        try write("untracked.txt", into: root, contents: "untracked")
        try gitRun(git, root, ["add", "tracked.txt"])
        var options = ExportOptions(); options.includeUntrackedFiles = false
        let manifest = try await ProjectExportService().preview(project: projectAt(root), options: options, destination: nil)
        XCTAssertEqual(manifest.files.map(\.relativePath), ["tracked.txt"])
    }

    func testFallbackExcludesCachesAndReportsGitUnavailable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("lib/main.dart", into: root, contents: "main")
        try write(".dart_tool/package_config.json", into: root, contents: "generated")
        try write("android/.gradle/state", into: root, contents: "generated")
        try write("ios/Runner/Info.plist", into: root, contents: "source")
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let manifest = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        XCTAssertFalse(manifest.usedGitIgnore)
        XCTAssertTrue(manifest.warnings.contains { $0.contains("Git is unavailable") })
        XCTAssertEqual(Set(manifest.files.map(\.relativePath)), ["lib/main.dart", "ios/Runner/Info.plist"])
    }

    func testSensitiveFilesAreListedByPathAndCanBeExcluded() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("lib/main.dart", into: root, contents: "main")
        try write(".env.production", into: root, contents: "do not inspect")
        try write("android/signing/upload.jks", into: root, contents: "do not inspect")
        try write("config/credentials.yaml", into: root, contents: "do not inspect")
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let preview = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        XCTAssertEqual(Set(preview.sensitivePaths), [".env.production", "android/signing/upload.jks", "config/credentials.yaml"])
        var options = ExportOptions()
        options.excludedSensitivePaths = Set(preview.sensitivePaths)
        let filtered = try await service.preview(project: projectAt(root), options: options, destination: nil)
        XCTAssertEqual(filtered.files.map(\.relativePath), ["lib/main.dart"])
    }

    func testSymlinksAreExcludedAndNeverDereferenced() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("project", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("lib/main.dart", into: root, contents: "main")
        try write("secret.txt", into: outside, contents: "secret")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: outside.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root.appendingPathComponent("loop"))
        let manifest = try await ProjectExportService(git: GitIgnoreService(gitURL: nil)).preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        XCTAssertEqual(manifest.files.map(\.relativePath), ["lib/main.dart"])
        XCTAssertGreaterThanOrEqual(manifest.warnings.filter { $0.contains("Symbolic link") }.count, 3)
    }

    func testUnicodeSpacesAndNewlinePathsArchiveAndExtract() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("lib/こんにちは app\nmain.dart", into: root, contents: "void main() {}")
        let project = projectAt(root)
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let manifest = try await service.preview(project: project, options: ExportOptions(), destination: nil)
        let output = root.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        let receipt = try await service.createArchive(manifest: manifest, destination: output, compression: .deflate) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.destination.path))
        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["lib/こんにちは app\nmain.dart"])
        let extracted = root.deletingLastPathComponent().appendingPathComponent("extract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extracted) }
        _ = try archive.extract(entry, to: extracted)
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "void main() {}")
    }

    func testOutputIsExcludedAndExistingArchiveIsNotOverwrittenWithoutApproval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("source.txt", into: root, contents: "source")
        let output = root.appendingPathComponent("bundle.zip")
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let manifest = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: output)
        XCTAssertFalse(manifest.files.contains { $0.relativePath == "bundle.zip" })
        try Data("existing".utf8).write(to: output)
        do {
            _ = try await service.createArchive(manifest: manifest, destination: output, compression: .deflate) { _ in }
            XCTFail("Expected destination conflict")
        } catch let error as ProjectExportError {
            guard case .destinationExists = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "existing")
    }

    func testDuplicateManifestPathsAreRejectedBeforeWriting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("source.txt", into: root, contents: "source")
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let preview = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        let manifest = ExportManifest(projectRoot: preview.projectRoot, files: [preview.files[0], preview.files[0]],
                                      totalBytes: preview.totalBytes * 2, excludedFileCount: 0,
                                      sensitivePaths: [], warnings: [], usedGitIgnore: false)
        let output = root.deletingLastPathComponent().appendingPathComponent("duplicate-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            _ = try await service.createArchive(manifest: manifest, destination: output, compression: .deflate) { _ in }
            XCTFail("Expected duplicate-path rejection")
        } catch let error as ProjectExportError {
            guard case .duplicatePath = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testGitIgnoreCanBeDisabledWithoutLosingGitTrackedFileSelection() async throws {
        guard let git = findGit() else { throw XCTSkip("Git is unavailable on this machine") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try gitRun(git, root, ["init", "-q"])
        try write("tracked.txt", into: root, contents: "tracked")
        try gitRun(git, root, ["add", "tracked.txt"])
        try write(".gitignore", into: root, contents: "ignored.txt\n")
        try write("ignored.txt", into: root, contents: "ignored")
        var options = ExportOptions(); options.respectGitIgnore = false
        let manifest = try await ProjectExportService().preview(project: projectAt(root), options: options, destination: nil)
        XCTAssertFalse(manifest.usedGitIgnore)
        XCTAssertTrue(manifest.warnings.contains { $0.contains("disabled") })
        XCTAssertTrue(Set(manifest.files.map(\.relativePath)).contains("ignored.txt"))
    }

    func testWorktreeNestedProjectGlobalAndInfoExcludesAndNULPaths() async throws {
        guard let git = findGit() else { throw XCTSkip("Git is unavailable on this machine") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try gitRun(git, repository, ["init", "-q"])
        try gitRun(git, repository, ["config", "user.name", "FVM GUI Tests"])
        try gitRun(git, repository, ["config", "user.email", "tests@example.invalid"])
        try write("packages/demo/lib/main.dart", into: repository, contents: "main")
        try write("packages/demo/.gitignore", into: repository, contents: "*.tmp\n!kept.tmp\n")
        try gitRun(git, repository, ["add", "."])
        try gitRun(git, repository, ["commit", "-q", "-m", "fixture"])
        try write(".git/info/exclude", into: repository, contents: "private.local\n")

        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try gitRun(git, repository, ["worktree", "add", "-q", "-b", "export-fixture", worktree.path, "HEAD"])
        let projectRoot = worktree.appendingPathComponent("packages/demo", isDirectory: true)
        try write("kept.tmp", into: projectRoot, contents: "keep")
        try write("hidden.tmp", into: projectRoot, contents: "ignore")
        try write("private.local", into: projectRoot, contents: "exclude")
        try write("global.secret", into: projectRoot, contents: "global exclude")
        try write("line\nbreak.txt", into: projectRoot, contents: "nul delimited")
        let globalIgnore = root.appendingPathComponent("global-ignore")
        try Data("global.secret\n".utf8).write(to: globalIgnore)
        let globalConfig = root.appendingPathComponent("gitconfig")
        try Data("[core]\n\texcludesFile = \(globalIgnore.path)\n".utf8).write(to: globalConfig)
        let executor = CLIExecutor(overrides: ["GIT_CONFIG_GLOBAL": globalConfig.path])
        let service = ProjectExportService(git: GitIgnoreService(executor: executor))
        let manifest = try await service.preview(project: projectAt(projectRoot), options: ExportOptions(), destination: nil)
        let paths = Set(manifest.files.map(\.relativePath))
        XCTAssertTrue(manifest.usedGitIgnore)
        XCTAssertTrue(paths.contains("lib/main.dart"))
        XCTAssertTrue(paths.contains("kept.tmp"))
        XCTAssertTrue(paths.contains("line\nbreak.txt"))
        XCTAssertFalse(paths.contains("hidden.tmp"))
        XCTAssertFalse(paths.contains("private.local"))
        XCTAssertFalse(paths.contains("global.secret"))
        XCTAssertFalse(paths.contains(".git"))
    }

    func testManifestRejectsModifiedAndDeletedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("file.txt", into: root, contents: "before")
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let manifest = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        try Data("a longer replacement".utf8).write(to: file)
        do { try await service.validate(manifest); XCTFail("Expected stale manifest") }
        catch let error as ProjectExportError { guard case .fileChanged = error else { return XCTFail("Unexpected error: \(error)") } }
        try FileManager.default.removeItem(at: file)
        do { try await service.validate(manifest); XCTFail("Expected missing file error") }
        catch let error as ProjectExportError { guard case .fileChanged = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    func testUnreadableSourceFailsWithoutLeavingPartialArchive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("private.txt", into: root, contents: "private")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let manifest = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        let output = root.appendingPathComponent("permission.zip")
        do {
            _ = try await service.createArchive(manifest: manifest, destination: output, compression: .deflate) { _ in }
            XCTFail("Expected an unreadable-file error")
        } catch is CancellationError { XCTFail("Unexpected cancellation") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".fvm-gui-export-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCancellationLeavesNoFinalArchiveOrTemporaryArchive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.bin")
        let block = Data(repeating: 0x6D, count: 1_048_576)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<32 { try handle.write(contentsOf: block) }
        try handle.close()
        let service = ProjectExportService(git: GitIgnoreService(gitURL: nil))
        let manifest = try await service.preview(project: projectAt(root), options: ExportOptions(), destination: nil)
        let output = root.appendingPathComponent("cancelled.zip")
        let signal = ProgressSignal()
        let task = Task {
            try await service.createArchive(manifest: manifest, destination: output, compression: .deflate) { update in
                if update.stage == .compressing, update.currentPath != nil { await signal.markStarted() }
            }
        }
        await signal.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".fvm-gui-export-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    private func projectAt(_ root: URL) -> FlutterProject {
        FlutterProject(path: root.path, name: root.lastPathComponent, type: .flutterApp)
    }

    @discardableResult private func write(_ relative: String, into root: URL, contents: String) throws -> URL {
        let url = URL(fileURLWithPath: root.path + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func findGit() -> URL? {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func gitRun(_ git: URL, _ root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = git
        process.arguments = ["-C", root.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
}

private actor ProgressSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func markStarted() {
        started = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
