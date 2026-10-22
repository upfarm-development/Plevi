import SwiftUI
import PleviDomain

/// Sleep timer options, presented from the player.
struct SleepTimerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private static let choices = [5, 10, 15, 30, 45, 60, 90]

    /// §4.8.1: "Kitchen iPad pauses when the timer ends. This iPhone
    /// doesn't need to stay open." — the timer runs on the target, not
    /// here, while remote.
    private var footer: String {
        guard let name = app.remote.controlledDeviceSubject else {
            return "Playback pauses when the timer ends. The app does not need to stay open."
        }
        return "\(name) pauses when the timer ends. This device doesn't need to stay open."
    }

    var body: some View {
        NavigationStack {
            List {
                if app.activePlayer.isSleepTimerActive {
                    Section {
                        if let minutes = app.activePlayer.sleepMinutesRemaining {
                            LabeledContent("Stopping in", value: minutes.counted("minute"))
                        } else if app.activePlayer.sleepsAtEndOfTrack {
                            LabeledContent("Stopping", value: "at the end of this song")
                        }
                        Button("Turn Off Timer", role: .destructive) {
                            app.activePlayer.cancelSleepTimer()
                            dismiss()
                        }
                    }
                }

                Section {
                    Button("At the end of this song") {
                        app.activePlayer.sleepAtEndOfTrack()
                        dismiss()
                    }
                    ForEach(Self.choices, id: \.self) { minutes in
                        Button(minutes.counted("minute")) {
                            app.activePlayer.startSleepTimer(minutes: minutes)
                            dismiss()
                        }
                    }
                } header: {
                    Text("Stop playing after")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .withoutBottomScrollEdgeBlur()
        .presentationDetents([.medium])
    }
}
