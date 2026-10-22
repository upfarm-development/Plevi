import Foundation
import AVFoundation
import PleviDomain

/// Peak levels for a track, for the waveform scrubber.
actor WaveformSampler {
    /// Points across a track — about one per point of width at phone size.
    /// Averaging any coarser is what turns a song into a sausage; the bar
    /// style thins them out again when drawing.
    static let barCount = 300

    /// Keyed by the whole `MediaID`, which carries the library it came from, and not by its raw
    /// string: one sampler lives for the whole session across every server and library, and two of
    /// them can hand out the same raw id for different songs — a…
    private var cache: [MediaID: [Float]] = [:]
    private var inFlight: [MediaID: Task<[Float]?, Never>] = [:]

    func waveform(for id: MediaID, url: URL) async -> [Float]? {
        if let cached = cache[id] { return cached }
        if let running = inFlight[id] { return await running.value }

        let task = Task<[Float]?, Never> { Self.peaks(of: url) }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        if let result { cache[id] = result }
        return result
    }

    /// Reads the file in blocks and measures each block.
    private static func peaks(of url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let framesPerBar = max(1, AVAudioFrameCount(file.length / Int64(barCount)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBar) else {
            return nil
        }

        var bars: [Float] = []
        bars.reserveCapacity(barCount)
        while bars.count < barCount, file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: framesPerBar)
            } catch {
                break
            }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }

            var sumOfSquares: Double = 0
            let channelCount = Int(format.channelCount)
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(samples[frame])
                    sumOfSquares += value * value
                }
            }
            let count = Double(Int(buffer.frameLength) * channelCount)
            bars.append(count > 0 ? Float((sumOfSquares / count).squareRoot()) : 0)
        }
        guard !bars.isEmpty else { return nil }

        // The same absolute scale the server's own analysis is put through,
        // so neither source stretches a song to fill the strip.
        guard bars.contains(where: { $0 > 0 }) else { return nil }
        let normalised = bars.map(WaveformLevels.forDisplay)

        // Padded if the file ended early, so the bar count is always the same
        // and the view never has to reason about a short array.
        return normalised + Array(repeating: 0, count: max(0, barCount - normalised.count))
    }
}
