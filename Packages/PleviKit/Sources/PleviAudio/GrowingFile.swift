import Foundation

/// When a file that is still arriving may be handed to the player, and how much of it has to be
/// there first.
public enum GrowingFile {
    /// The first bytes a caller needs to decide with.
    public static let sniffLength = 16

    /// What a file's first bytes say it is, where that matters here.
    public enum Container: Sendable, Equatable {
        case flac
        case aiff
        case caf
        /// MPEG-4: ALAC, and AAC in `.m4a`.
        case mp4
        /// Anything else, including MP3, ADTS, WAV and Ogg, and a file too
        /// short to tell.
        case other
    }

    public static func container(of head: Data) -> Container {
        let bytes = Array(head.prefix(sniffLength))
        func tag(_ text: String, at offset: Int = 0) -> Bool {
            let wanted = Array(text.utf8)
            guard bytes.count >= offset + wanted.count else { return false }
            return Array(bytes[offset..<offset + wanted.count]) == wanted
        }
        if tag("fLaC") { return .flac }
        if tag("FORM") { return .aiff }
        if tag("caff") { return .caf }
        if tag("ftyp", at: 4) { return .mp4 }
        return .other
    }

    /// Whether the length this file reports while it is incomplete can be believed.
    public static func declaresLength(head: Data, isConversion: Bool) -> Bool {
        if isConversion { return false }
        switch container(of: head) {
        case .flac, .aiff, .caf, .mp4: return true
        case .other: return false
        }
    }

    /// How many bytes make a start worth making.
    public static let maximumStartBytes: Int64 = 1_500_000
    /// Below this a start is not worth the handover, whatever the rate.
    public static let minimumStartBytes: Int64 = 64_000
    /// How much audio should be on disk before playing from a partial file.
    public static let startSeconds: Double = 8

    /// The bytes that have to have arrived before the file is announced.
    public static func startBytes(kbps: Int?) -> Int64 {
        guard let kbps, kbps > 0 else { return maximumStartBytes }
        let bytesPerSecond = Double(kbps) * 1000 / 8
        let wanted = Int64((bytesPerSecond * startSeconds).rounded())
        return min(maximumStartBytes, max(minimumStartBytes, wanted))
    }

    /// Whether the file is so nearly here that handing it over part-way costs more than it saves.
    public static func isNearlyComplete(total: Int64?, startBytes: Int64) -> Bool {
        guard let total else { return false }
        return total <= startBytes * 2
    }
}

/// What to do when the fetch of a song dies after the engine has already been handed the part that
/// arrived.
public enum CutOffPlan {
    public enum Action: Equatable, Sendable {
        /// Tell the engine that what it has is all there is.
        case playOutWhatArrived
        /// Start the fetch again, through the ordinary retries.
        case fetchAgain
    }

    /// How far into the song the play head may be for a fresh start to pass
    /// unnoticed.
    public static let earlySeconds: TimeInterval = 5

    /// - Parameters: - heard: how far into the song the play head is.
    public static func action(
        heard: TimeInterval,
        arrived: TimeInterval?,
        expected: TimeInterval?,
        canRetry: Bool
    ) -> Action {
        guard canRetry, heard < earlySeconds else { return .playOutWhatArrived }
        // A song that has all but arrived is better played than fetched again:
        // a connection that dies on the last byte fails the fetch exactly as
        // one that dies in the middle does.
        if let arrived, let expected, expected > 0,
           arrived >= expected - max(1, expected * 0.02) {
            return .playOutWhatArrived
        }
        return .fetchAgain
    }
}
