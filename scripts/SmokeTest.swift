// Compile with the Core/CLI, Models, Errors and FVM service/parser sources.
// Requires FVM_CACHE_PATH to point inside a new temporary directory.
import Foundation

@main struct SmokeTest {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executor = CLIExecutor()
        let installation = try await ExecutableLocator(executor: executor).locate(manualPath: nil)
        let service = FVMCLIService(installation: installation, executor: executor)
        if environment["FVM_GUI_ISOLATED_SMOKE"] == "1" {
            guard let cache = environment["FVM_CACHE_PATH"], cache.hasPrefix("/private/tmp/fvm-gui-smoke-") else { throw FVMError.message("An isolated temporary FVM_CACHE_PATH is required.") }
            let root = URL(fileURLWithPath: cache).deletingLastPathComponent()
            let sdk = URL(fileURLWithPath: cache).appendingPathComponent("versions/3.47.2")
            let fm = FileManager.default
            try fm.createDirectory(at: sdk.appendingPathComponent("bin/cache/dart-sdk/bin"), withIntermediateDirectories: true)
            try Data("3.47.2".utf8).write(to: sdk.appendingPathComponent("version"))
            for name in ["flutter", "dart"] {
                let file = sdk.appendingPathComponent("bin/\(name)")
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            let project = root.appendingPathComponent("Flutter project")
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("name: fvm_gui_smoke\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\n".utf8).write(to: project.appendingPathComponent("pubspec.yaml"))
            let installed = try await service.installed()
            guard installed.count == 1, installed.first?.directory == sdk.path else { throw FVMError.message("Cache isolation failed") }
            // Existing synthetic SDK only: this does not test downloading Flutter.
            try await service.modify(["install", "3.47.2", "--no-setup", "--skip-pub-get"], directory: nil, output: nil)
            try await service.modify(["global", "3.47.2"], directory: nil, output: nil)
            try await service.modify(["use", "3.47.2", "--skip-setup", "--skip-pub-get"], directory: project, output: nil)
            let metadata = try await service.project(at: project)
            guard metadata.version == "3.47.2" else { throw FVMError.message("Project pin verification failed") }
            try await service.modify(["remove", "3.47.2"], directory: nil, output: nil)
            print("PASS: real FVM \(installation.version), isolated synthetic cached install/global/use/remove and project inspection")
        } else {
            let sdks = try await service.installed()
            let releases = try await service.releases()
            print("PASS: real FVM \(installation.version), \(sdks.count) installed SDKs, \(releases.count) available releases")
        }
    }
}
