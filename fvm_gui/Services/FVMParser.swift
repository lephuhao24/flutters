import Foundation

struct FVMParser: Sendable {
    func sdks(_ text: String) throws -> [FlutterSDK] {
        struct Payload: Decodable { let versions: [FlutterSDK] }
        return try decode(Payload.self, text).versions
    }
    func releases(_ text: String) throws -> [FlutterRelease] {
        struct Payload: Decodable { let versions: [FlutterRelease] }
        var seen = Set<String>()
        return try decode(Payload.self, text).versions.filter { seen.insert($0.id).inserted }
    }
    func project(_ text: String) throws -> (name: String, version: String?, isFlutter: Bool) {
        struct Payload: Decodable {
            struct Project: Decodable {
                struct Pin: Decodable { let name: String }
                let name: String
                let pinnedVersion: Pin?
                let isFlutter: Bool
            }
            let project: Project
        }
        let project = try decode(Payload.self, text).project
        return (project.name, project.pinnedVersion?.name, project.isFlutter)
    }
    func globalLink(_ text: String) throws -> URL {
        struct Payload: Decodable { struct Context: Decodable { let globalCacheLink: String }; let context: Context }
        return URL(fileURLWithPath: try decode(Payload.self, text).context.globalCacheLink)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
        catch { throw FVMError.message("FVM returned an unexpected response. Check CLI compatibility or network access. Details: \(error.localizedDescription)") }
    }
}
