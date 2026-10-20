import Foundation
import Yams

struct ParsedProjectManifest: Sendable {
    let name: String
    let type: FlutterProjectType
    let dartSDKConstraint: String?
    let flutterSDKConstraint: String?
    let platforms: [String]
}

struct ProjectManifestParser: Sendable {
    private static let platformNames = ["ios", "android", "macos", "web", "linux", "windows"]

    func parse(_ data: Data, directory: URL) throws -> ParsedProjectManifest {
        guard data.count <= 2_000_000 else { throw FVMError.message("pubspec.yaml is larger than the supported 2 MB limit.") }
        guard let source = String(data: data, encoding: .utf8) else { throw FVMError.message("pubspec.yaml is not valid UTF-8.") }
        let document: Any
        do {
            guard let loaded = try Yams.load(yaml: source) else { throw FVMError.message("pubspec.yaml is empty.") }
            document = loaded
        }
        catch { throw FVMError.message("Malformed pubspec.yaml: \(error.localizedDescription)") }
        guard let manifest = document as? [String: Any] else { throw FVMError.message("pubspec.yaml must contain a YAML mapping.") }
        guard let name = manifest["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FVMError.message("pubspec.yaml must declare a package name.")
        }

        let dependencies = (manifest["dependencies"] as? [String: Any] ?? [:])
            .merging(manifest["dev_dependencies"] as? [String: Any] ?? [:]) { current, _ in current }
        let isFlutter = dependencies.values.contains { dependency in
            (dependency as? [String: Any])?["sdk"] as? String == "flutter"
        }
        let flutter = manifest["flutter"] as? [String: Any] ?? [:]
        let plugin = flutter["plugin"] as? [String: Any]
        let type: FlutterProjectType
        if !isFlutter { type = .dartPackage }
        else if let plugin, !plugin.isEmpty { type = .flutterPlugin }
        else {
            let platforms = Self.platformNames.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            let isApp = FileManager.default.fileExists(atPath: directory.appendingPathComponent("lib/main.dart").path)
            type = isApp || !platforms.isEmpty ? .flutterApp : .flutterPackage
        }
        let environment = manifest["environment"] as? [String: Any] ?? [:]
        let constraint = environment["sdk"] as? String
        let flutterConstraint = environment["flutter"] as? String
        let platforms = Self.platformNames.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        return ParsedProjectManifest(name: name, type: type, dartSDKConstraint: constraint,
                                     flutterSDKConstraint: flutterConstraint, platforms: platforms)
    }
}
