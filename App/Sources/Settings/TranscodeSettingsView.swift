import SwiftUI
import PleviAudio
import PleviDomain

/// One transcoding policy — streaming or downloads — on its own page.
struct TranscodeSettingsView: View {
    @Environment(AppModel.self) private var app
    let title: String
    @Binding var policy: TranscodePolicy

    /// What the server in use can produce.
    private var formats: [TranscodeCodec] {
        // With no server connected nothing is known about what it can make:
        // every codec is listed, rather than a pair that matches neither
        // backend and got the stored choice rewritten to fit it.
        app.provider?.supportedTranscodeCodecs ?? TranscodeCodec.allCases
    }

    private static func label(for codec: TranscodeCodec) -> String {
        switch codec {
        case .aac: "AAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        }
    }

    var body: some View {
        List {
            // An inline picker draws its options as rows of the section it is
            // in. Nested inside anything else it renders but stops responding,
            // which is how the choices here became unselectable.
            Section("When to convert") {
                Picker("When to convert", selection: $policy.threshold) {
                    ForEach(TranscodePolicy.Threshold.allCases) { threshold in
                        Text(threshold.label).tag(threshold)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if policy.threshold == .aboveBitRate {
                Section {
                    SettingItem {
                        Picker("Above", selection: $policy.bitRateLimitKbps) {
                            ForEach([128, 192, 256, 320, 500, 1000], id: \.self) { rate in
                                Text("\(rate) kbps").tag(rate)
                            }
                        }
                    }
                }
            }

            // Shown for every threshold, "Only if unplayable" included: that setting still
            // transcodes anything the device cannot decode, and this is what it will be transcoded
            // to.
            Section("Convert to") {
                // Only what this server will actually produce. Plex makes
                // MP3 whatever it is asked for, so a choice here would be
                // a promise the server does not keep.
                if formats.count > 1 {
                    SettingRow(title: "Format") {
                        Picker("Format", selection: $policy.codec) {
                            ForEach(formats, id: \.rawValue) { codec in
                                Text(Self.label(for: codec)).tag(codec.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } else if let only = formats.first {
                    SettingItem(caption: "This server only supports \(Self.label(for: only)).") {
                        LabeledContent("Format", value: Self.label(for: only))
                    }
                }
                SettingItem {
                    Picker("Bit rate", selection: $policy.targetBitRateKbps) {
                        ForEach(TranscodePolicy.offeredBitRates, id: \.self) { rate in
                            Text("\(rate) kbps").tag(rate)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        // A codec that is no longer offered — Opus, or AAC on a Plex server —
        // would leave the picker showing nothing at all. So would a rate: 96
        // was on the list until build 367.
        .task(id: formats.map(\.rawValue).joined()) {
            // Only against a real server's list. The codec is one global
            // setting shared by every server, so a page opened before a
            // server is connected has no business changing it.
            if app.provider != nil,
               !formats.contains(where: { $0.rawValue == policy.codec }),
               let first = formats.first {
                policy.codec = first.rawValue
            }
            if !TranscodePolicy.offeredBitRates.contains(policy.targetBitRateKbps) {
                policy.targetBitRateKbps = TranscodePolicy.offeredRate(
                    nearest: policy.targetBitRateKbps
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
