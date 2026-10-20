import Foundation
import Observation

struct ActivityEntry: Identifiable {
    let id: UUID
    let command: String
    let started: Date
    var operationStatus: OperationStatus = .running
    let projectPath: String?
    var status: String { operationStatus.rawValue }
    var output = ""
    var exitCode: Int32?
    var duration: Duration?
}
@MainActor @Observable final class ActivityStore {
    private(set) var entries: [ActivityEntry] = []
    func begin(command: String, projectPath: String? = nil, id: UUID = UUID()) -> UUID {
        entries.insert(ActivityEntry(id: id, command: command, started: Date(), projectPath: projectPath), at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
        return id
    }
    func append(_ text: String, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let combined = String((entries[index].output + text).suffix(200_000))
        let clean = combined.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "\n")
        entries[index].output = clean
    }
    func output(for id: UUID) -> String { entries.first(where: { $0.id == id })?.output ?? "" }
    func finish(_ id: UUID, status: OperationStatus, exitCode: Int32? = nil, duration: Duration? = nil) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].operationStatus = status
            entries[index].exitCode = exitCode
            entries[index].duration = duration
        }
    }
    func clearCompleted(projectPath: String? = nil) {
        entries.removeAll { entry in
            entry.operationStatus != .running && (projectPath == nil || entry.projectPath == projectPath)
        }
    }
}
