import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DartSymbolicationView: View {
    let record: BuildHistoryRecord
    let storage: ReleaseStorageService
    let executor: any CLIExecuting

    @Environment(\.dismiss) private var dismiss
    @State private var metadata: ReleaseMetadata?
    @State private var symbols: [URL] = []
    @State private var selectedSymbolPath = ""
    @State private var crashText = ""
    @State private var resultText = ""
    @State private var errorText: String?
    @State private var runningTask: Task<Void, Never>?
    @State private var isRunning = false

    private var flutterExecutable: URL? {
        guard let path = metadata?.flutterExecutablePath, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var selectedSymbol: URL? { symbols.first { $0.path == selectedSymbolPath } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Symbolize Dart Crash Log").font(.title2.weight(.semibold))
                    Text("\(record.configuration.platform.title) · \(record.configuration.flavor ?? "No Flavor") · Flutter \(record.sdkLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }

            if let metadata {
                LabeledContent("Flutter SDK", value: metadata.flutterExecutablePath).font(.caption)
                if !symbols.isEmpty {
                    Picker("Dart symbol file", selection: $selectedSymbolPath) {
                        ForEach(symbols, id: \.path) { symbol in
                            Text(symbol.lastPathComponent).tag(symbol.path)
                        }
                    }
                    .help("Choose the symbol file for the matching platform and architecture.")
                } else {
                    ContentUnavailableView("No Dart Symbols", systemImage: "doc.questionmark", description: Text("This archived build has no symbol files."))
                }
            } else {
                ContentUnavailableView("Release Metadata Unavailable", systemImage: "exclamationmark.triangle", description: Text("This historical build does not contain the SDK and symbol metadata required for symbolication."))
            }

            HStack {
                Text("Dart crash stack trace").font(.headline)
                Spacer()
                Button("Import…") { importCrashLog() }
            }
            TextEditor(text: $crashText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Button("Symbolize") { symbolize() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || crashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSymbol == nil || flutterExecutable == nil)
                if isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { runningTask?.cancel() }
                }
                Spacer()
                if !resultText.isEmpty {
                    Button("Copy Result") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resultText, forType: .string) }
                    Button("Export…") { exportResult() }
                }
            }

            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            TextEditor(text: .constant(resultText.isEmpty ? "Symbolicated output will appear here." : resultText))
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 700)
        .task { await loadRelease() }
        .onDisappear { runningTask?.cancel() }
    }

    private func loadRelease() async {
        guard let path = record.releaseDirectory else { errorText = "The archived release directory is missing."; return }
        do {
            let loaded = try await storage.loadMetadata(at: URL(fileURLWithPath: path, isDirectory: true))
            metadata = loaded
            symbols = loaded.symbolFiles.map { URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent($0) }
                .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            selectedSymbolPath = symbols.first?.path ?? ""
            if loaded.flutterExecutablePath.isEmpty || !FileManager.default.isExecutableFile(atPath: loaded.flutterExecutablePath) {
                errorText = "The Flutter SDK used for this release is unavailable at its recorded path. Select or reinstall that SDK to symbolize this crash."
            }
        } catch { errorText = error.localizedDescription }
    }

    private func importCrashLog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .log]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { crashText = try String(contentsOf: url, encoding: .utf8); errorText = nil }
        catch { errorText = "Crash log could not be read: \(error.localizedDescription)" }
    }

    private func symbolize() {
        guard let executable = flutterExecutable, let symbol = selectedSymbol else {
            errorText = "The Flutter executable or matching Dart symbol file is unavailable."
            return
        }
        guard !crashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "Paste or import a Dart stack trace first."
            return
        }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("fvmgui-crash-\(UUID().uuidString).txt")
        do { try Data(crashText.utf8).write(to: input, options: .atomic) }
        catch { errorText = "Crash log could not be prepared: \(error.localizedDescription)"; return }
        errorText = nil
        resultText = ""
        isRunning = true
        runningTask = Task {
            defer { try? FileManager.default.removeItem(at: input) }
            do {
                let response = try await storage.withStorageAccess(to: symbol) {
                    try await executor.run(
                        executable: executable,
                        arguments: ["symbolize", "-i", input.path, "-d", symbol.path],
                        directory: nil,
                        timeout: .seconds(120),
                        output: { event in
                            await MainActor.run { resultText += event.text }
                        }
                    )
                }
                if response.exitCode != 0 {
                    errorText = "Flutter symbolize exited with code \(response.exitCode). Check that this symbol file matches the crash architecture."
                    if resultText.isEmpty { resultText = response.stdout + response.stderr }
                } else if resultText.isEmpty {
                    resultText = response.stdout + response.stderr
                }
            } catch is CancellationError {
                errorText = "Symbolication was cancelled."
            } catch {
                errorText = "Symbolication failed: \(error.localizedDescription)"
            }
            isRunning = false
            runningTask = nil
        }
    }

    private func exportResult() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "symbolicated-crash.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(resultText.utf8).write(to: url, options: .atomic) }
        catch { errorText = "Symbolicated output could not be exported: \(error.localizedDescription)" }
    }
}
