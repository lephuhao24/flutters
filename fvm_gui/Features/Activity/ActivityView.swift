import SwiftUI

struct ActivityView: View {
    @Bindable var container: AppContainer
    var body: some View {
        Group {
            if container.activity.entries.isEmpty { ContentUnavailableView("No Activity", systemImage: "terminal", description: Text("SDK operations and their output appear here.")) }
            else {
                List(container.activity.entries) { entry in
                    DisclosureGroup {
                        ScrollView([.horizontal, .vertical]) {
                            Text(entry.output.isEmpty ? "Waiting for output…" : entry.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.frame(minHeight: 100, maxHeight: 360).background(.background.secondary)
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) { Text(entry.command).font(.system(.body, design: .monospaced)); Text(entry.started, style: .date).font(.caption) + Text(" ") + Text(entry.started, style: .time).font(.caption) }
                            Spacer()
                            Text(entry.status).foregroundStyle(entry.status == "Failed" ? .red : .secondary)
                            if entry.status == "Running" { ProgressView().controlSize(.small); Button("Cancel") { container.cancel() } }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
    }
}
