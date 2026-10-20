import Foundation

struct FlutterDoctorParseResult: Sendable, Equatable {
    let categories: [FlutterDoctorCategory]
    let formatRecognized: Bool
    let hasCompletionSummary: Bool
    let message: String?

    var overallStatus: FlutterDiagnosticStatus {
        guard !categories.isEmpty else { return .unknown }
        if categories.contains(where: { $0.status == .failed }) { return .failed }
        if categories.contains(where: { $0.status == .warning }) { return .warning }
        if categories.contains(where: { $0.status == .unknown }) { return .unknown }
        return hasCompletionSummary ? .passed : .unknown
    }
}

enum FlutterDoctorParserError: LocalizedError {
    case outputTooLarge
    var errorDescription: String? {
        switch self { case .outputTooLarge: "Flutter Doctor output exceeded the 10 MB structured parsing limit; raw output is still available." }
    }
}

/// Parses Flutter's human-readable `flutter doctor --verbose` output conservatively.
/// The output remains available verbatim on the report even when no category headers match.
struct FlutterDoctorParser {
    private let headerExpression = try! NSRegularExpression(pattern: #"^\s*\[([^\]]+)\]\s+(.+?)\s*$"#)
    private let ansiExpression = try! NSRegularExpression(pattern: #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\))"#)

    func parse(_ rawOutput: String) throws -> FlutterDoctorParseResult {
        guard rawOutput.utf8.count <= 10_000_000 else { throw FlutterDoctorParserError.outputTooLarge }
        let cleanOutput = stripANSI(rawOutput)
        let completionSummary = cleanOutput.localizedCaseInsensitiveContains("No issues found!") ||
            cleanOutput.localizedCaseInsensitiveContains("Doctor found issues in")
        var sections: [(header: String, marker: String, lines: [String])] = []
        var foundHeader = false
        for line in cleanOutput.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = headerExpression.firstMatch(in: line, range: range),
               let markerRange = Range(match.range(at: 1), in: line),
               let headerRange = Range(match.range(at: 2), in: line) {
                foundHeader = true
                sections.append((String(line[headerRange]).trimmingCharacters(in: .whitespaces),
                                 String(line[markerRange]).trimmingCharacters(in: .whitespaces), []))
            } else if foundHeader, let lastIndex = sections.indices.last {
                let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let isCompletionSummary = message.localizedCaseInsensitiveContains("No issues found!") ||
                    message.localizedCaseInsensitiveContains("Doctor found issues in")
                if !message.isEmpty && !isCompletionSummary { sections[lastIndex].lines.append(message) }
            }
        }

        let categories = sections.enumerated().map { index, section in
            let kind = Self.kind(for: section.header)
            let body = ([section.header] + section.lines).joined(separator: "\n")
            return FlutterDoctorCategory(identifier: "\(kind.identifier)-\(index)", name: kind.name,
                                         status: Self.status(for: section.marker),
                                         diagnosticMessages: section.lines,
                                         suggestedActions: suggestedActions(for: body, kind: kind),
                                         rawOutput: "[\(section.marker)] \(section.header)\n" + section.lines.joined(separator: "\n"))
        }
        return FlutterDoctorParseResult(categories: categories, formatRecognized: !categories.isEmpty,
                                        hasCompletionSummary: completionSummary,
                                        message: categories.isEmpty ? "No Flutter Doctor diagnostic category headers were recognized. Review the raw output." : nil)
    }

    func stripANSI(_ value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return ansiExpression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }

    private func suggestedActions(for body: String, kind: (identifier: String, name: String)) -> [FlutterDoctorSuggestedAction] {
        let text = body.lowercased()
        var actions: [FlutterDoctorSuggestedAction] = []
        func add(_ id: String, _ title: String, _ instructions: String, _ url: String? = nil) {
            actions.append(FlutterDoctorSuggestedAction(id: id, title: title, instructions: instructions, documentationURL: url))
        }

        if text.contains("command line tools") && (text.contains("not installed") || text.contains("missing") || text.contains("unable")) {
            add("xcode-cli-tools", "Install Xcode Command Line Tools", "Run `xcode-select --install`, then select the intended Xcode in Xcode > Settings > Locations.", "https://developer.apple.com/xcode/")
        }
        if kind.identifier == "android-toolchain" && (text.contains("android sdk") && (text.contains("not found") || text.contains("not installed") || text.contains("unable to locate"))) {
            add("android-sdk", "Install Android SDK components", "Open Android Studio > Tools > SDK Manager and install the Android SDK and Command-line Tools. Re-run Flutter Doctor afterward.", "https://docs.flutter.dev/platform-integration/android/setup")
        }
        if text.contains("license") && (text.contains("not accepted") || text.contains("status unknown") || text.contains("accept")) {
            add("android-licenses", "Review Android SDK licenses", "Run `flutter doctor --android-licenses` in Terminal and review each license prompt. This app will not accept licenses for you.", "https://docs.flutter.dev/install/troubleshoot")
        }
        if text.contains("cocoapods") && (text.contains("not installed") || text.contains("not available") || text.contains("missing")) {
            add("cocoapods", "Install CocoaPods", "Install CocoaPods using the method appropriate for your Ruby/Homebrew setup, then run Flutter Doctor again.", "https://cocoapods.org/")
        }
        if kind.identifier == "android-studio" && (text.contains("not installed") || text.contains("not available") || text.contains("not found")) {
            add("android-studio", "Install Android Studio", "Install Android Studio and its Flutter/Android SDK components, then re-run Flutter Doctor.", "https://developer.android.com/studio")
        }
        return actions
    }

    private static func status(for marker: String) -> FlutterDiagnosticStatus {
        switch marker {
        case "✓", "✔", "√": .passed
        case "!": .warning
        case "✗", "✘", "x", "X": .failed
        default: .unknown
        }
    }

    private static func kind(for heading: String) -> (identifier: String, name: String) {
        let value = heading.lowercased()
        if value.hasPrefix("flutter") { return ("flutter-sdk", "Flutter SDK") }
        if value.hasPrefix("xcode") { return ("xcode", "Xcode") }
        if value.hasPrefix("android toolchain") { return ("android-toolchain", "Android Toolchain") }
        if value.hasPrefix("android studio") { return ("android-studio", "Android Studio") }
        if value.hasPrefix("connected device") || value.hasPrefix("connected devices") { return ("connected-devices", "Connected Devices") }
        if value.hasPrefix("network resources") { return ("network-resources", "Network Resources") }
        return ("other", heading)
    }
}
