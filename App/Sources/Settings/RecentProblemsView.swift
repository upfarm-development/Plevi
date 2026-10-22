import SwiftUI

/// What has gone wrong this session, in the order it happened.
struct RecentProblemsView: View {
    @Environment(AppModel.self) private var app

    /// A debug switch for testing a hypothesis about the Plex transcoder without a rebuild.
    @State private var reportsPositionToPlex = TranscodeDebugSettings.reportsPositionToPlex

    private static let time: Date.FormatStyle = .dateTime.hour().minute().second()

    private static func combinedPlaybackLog() -> String {
        var combined = ""
        let previous = TranscodeLog.previousSessionLog()
        if !previous.isEmpty {
            combined += "— Previous run —\n" + previous + "\n"
        }
        combined += "— This run —\n" + TranscodeLog.currentSessionLog()
        return combined
    }

    var body: some View {
        List {
            Section {
                Button("Copy playback log") {
                    UIPasteboard.general.string = Self.combinedPlaybackLog()
                }
            }

            Section("Transcoding diagnostics") {
                Toggle("Report position to Plex", isOn: $reportsPositionToPlex)
                    .onChange(of: reportsPositionToPlex) { _, newValue in
                        TranscodeDebugSettings.reportsPositionToPlex = newValue
                    }
            }

            if app.recentProblems.isEmpty {
                ContentUnavailableView(
                    "Nothing has gone wrong",
                    systemImage: "checkmark.circle",
                    description: Text("Errors shown on screen are kept here for the rest of the session.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(app.recentProblems) { problem in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.message)
                            .font(.callout)
                            .textSelection(.enabled)
                        Text(problem.at.formatted(Self.time))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Recent Problems")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !app.recentProblems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = app.recentProblems
                            .map { problem in
                                let header = "\(problem.at.formatted(Self.time))  \(problem.message)"
                                guard !problem.context.isEmpty else { return header }
                                let trail = problem.context.map { "    \($0)" }.joined(separator: "\n")
                                return header + "\n" + trail
                            }
                            .joined(separator: "\n")
                    }
                }
            }
        }
    }
}
