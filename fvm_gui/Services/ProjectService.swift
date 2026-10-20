import Foundation
import Yams

protocol ProjectManifestReading: Sendable {
    func read(_ inputURL: URL, within inputRoot: URL) async throws -> FlutterProject
}

protocol ProjectServicing: Sendable {
    func inspect(_ url: URL, fvm: any FVMService) async throws -> FlutterProject
    func readManifest(_ url: URL, within root: URL) async throws -> FlutterProject
}
extension ProjectServicing {
    func readManifest(_ url: URL, within root: URL) async throws -> FlutterProject {
        try await ProjectManifestReader().read(url, within: root)
    }
}

actor ProjectManifestReader: ProjectManifestReading {
    private let fileSystem: any FileSystemOperating
    private let parser = ProjectManifestParser()
    init(fileSystem: any FileSystemOperating = LocalFileSystem()) { self.fileSystem = fileSystem }

    func read(_ inputURL: URL, within inputRoot: URL) async throws -> FlutterProject {
        try Task.checkCancellation()
        let url = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let root = inputRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isInside(url, root: root), await fileSystem.isDirectory(url) else {
            throw FVMError.message("Project folder is missing, inaccessible, or outside the selected scan directory.")
        }
        let pubspec = url.appendingPathComponent("pubspec.yaml")
        guard await fileSystem.exists(pubspec) else { throw FVMError.message("Select a project folder containing pubspec.yaml.") }
        guard !(await fileSystem.isSymbolicLink(pubspec)) else { throw FVMError.message("Symbolic-link pubspec.yaml files are skipped for safety.") }
        let manifestData = try await fileSystem.read(pubspec)
        let parsed = try parser.parse(manifestData, directory: url)
        var config = url
        var source: URL?
        while Self.isInside(config, root: root) {
            try Task.checkCancellation()
            let candidate = config.appendingPathComponent(".fvmrc")
            if await fileSystem.exists(candidate), !(await fileSystem.isSymbolicLink(candidate)) { source = candidate; break }
            if config.path == root.path { break }
            config.deleteLastPathComponent()
        }
        var configuredVersion: String?
        if let source {
            let data = try await fileSystem.read(source)
            guard data.count <= 64_000 else { throw FVMError.message("FVM configuration is larger than the supported 64 KB limit.") }
            do {
                guard let text = String(data: data, encoding: .utf8) else { throw FVMError.message("FVM configuration is not valid UTF-8.") }
                let value: Any
                if source.pathExtension == "json" { value = try JSONSerialization.jsonObject(with: data) }
                else { value = try Yams.load(yaml: text) as Any }
                guard let map = value as? [String: Any] else { throw FVMError.message("FVM configuration must contain a YAML or JSON mapping.") }
                configuredVersion = map["flutter"] as? String ?? map["flutterSdkVersion"] as? String
                if configuredVersion?.isEmpty == true { configuredVersion = nil }
            } catch { throw FVMError.message("Malformed FVM configuration at \(source.path): \(error.localizedDescription)") }
        }
        return FlutterProject(path: url.path, name: parsed.name, configurationSource: source?.path,
                              type: parsed.type, configuredVersion: configuredVersion,
                              dartSDKConstraint: parsed.dartSDKConstraint, flutterSDKConstraint: parsed.flutterSDKConstraint,
                              platforms: parsed.platforms)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }
}

actor ProjectService: ProjectServicing {
    func inspect(_ inputURL: URL, fvm: any FVMService) async throws -> FlutterProject {
        let url = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let parsed = try await readManifest(url, within: URL(fileURLWithPath: "/", isDirectory: true))
        guard parsed.type != .dartPackage else { throw FVMError.message("Dart-only packages do not use an FVM Flutter SDK.") }
        let info = try await fvm.project(at: url)
        return FlutterProject(path: parsed.path, name: info.name, version: info.version,
                              configurationSource: parsed.configurationSource, issue: nil, type: parsed.type,
                              configuredVersion: parsed.configuredVersion, dartSDKConstraint: parsed.dartSDKConstraint,
                              flutterSDKConstraint: parsed.flutterSDKConstraint,
                              platforms: parsed.platforms)
    }
}
