import Foundation

/// How far ahead of the song playing the app reads, decided per song rather than once per pass.
public enum ReadAhead {
    /// Whether the song `offset` places past the one playing may still be fetched, given the depth
    /// the setting allows *now*.
    public static func mayFetch(offset: Int, allowedDepth: Int) -> Bool {
        offset < max(1, allowedDepth)
    }
}
