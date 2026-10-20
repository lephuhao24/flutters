import SwiftUI
import AppKit

/// This command is display/copy-only. It is never passed to CLIExecutor.
enum HomebrewInstructions {
    static let command = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
}
struct DependencySetupView: View {
    @Bindable var container: AppContainer
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Set Up FVM GUI", systemImage: "shippingbox.circle").font(.largeTitle)
                Text(container.setup.state.rawValue).font(.title2).accessibilityIdentifier("dependencySetupState")
                if container.setup.state == .checking { ProgressView("Checking your existing installation…") }
                if let detail = container.setup.detail {
                    Text(detail).foregroundStyle(container.setup.state == .failed ? .red : .secondary).textSelection(.enabled)
                }
                if let brew = container.setup.homebrew {
                    Label("Homebrew available", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Text(brew.executable.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if container.setup.state == .missingHomebrew {
                    Text("Install Homebrew in Terminal using the official instructions, complete its post-install steps, then check again. This app only copies the command; it does not run the Homebrew installer.")
                    Text(HomebrewInstructions.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(copied ? "Copied" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(HomebrewInstructions.command, forType: .string)
                        }
                        Button("Open Homebrew Website") { openHomebrewWebsite() }
                    }
                }
                if container.setup.state == .installing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(container.setup.cancelling ? "Stopping Homebrew…" : "Installing and verifying FVM…")
                        Spacer()
                        Button("Cancel", role: .cancel) { container.setup.cancel() }.disabled(container.setup.cancelling)
                    }
                }
                HStack {
                    if container.setup.homebrew != nil && container.setup.installation == nil && !container.setup.isWorking {
                        Button("Install FVM") { Task { await container.installFVM() } }
                            .buttonStyle(.borderedProminent).disabled(container.busy || container.detecting)
                    }
                    Button("Check Again") { Task { await container.detect() } }.disabled(container.setup.isWorking || container.busy || container.detecting)
                }
                if !container.setup.output.isEmpty {
                    Text("Installation Output").font(.headline)
                    ScrollView([.horizontal, .vertical]) {
                        Text(container.setup.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(height: 220).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Homebrew installation output")
                }
                Divider()
                ExecutablePathsView(container: container)
            }.padding(32).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func openHomebrewWebsite() {
        guard let url = URL(string: "https://brew.sh/") else { return }
        openURL(url) { accepted in
            if !accepted { container.error = "Could not open the Homebrew website. Visit https://brew.sh/ in your browser." }
        }
    }
}

struct ExecutablePathsView: View {
    @Bindable var container: AppContainer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Existing Executables").font(.headline)
            Text("Leave a path empty for automatic detection. Select executables you trust.").font(.caption).foregroundStyle(.secondary)
            TextField("FVM path (Homebrew, Dart Pub, or custom)", text: $container.manualPath).textFieldStyle(.roundedBorder).accessibilityLabel("FVM executable path")
            Button("Choose FVM Executable…") { choose(homebrew: false) }
            TextField("Homebrew path (optional)", text: $container.manualBrewPath).textFieldStyle(.roundedBorder).accessibilityLabel("Homebrew executable path")
            Button("Choose Homebrew Executable…") { choose(homebrew: true) }
            Button("Validate & Refresh") { Task { await container.detect() } }
        }.disabled(container.busy || container.detecting || container.setup.isWorking)
    }
    private func choose(homebrew: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = homebrew ? "Select Homebrew" : "Select FVM"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard !container.busy, !container.detecting, !container.setup.isWorking else { return }
                if homebrew { container.manualBrewPath = url.path } else { container.manualPath = url.path }
                await container.detect()
            }
        }
    }
}
