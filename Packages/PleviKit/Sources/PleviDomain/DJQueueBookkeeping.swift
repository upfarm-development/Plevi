import Foundation

/// The two small rules every DJ's queue bookkeeping reduces to, kept as plain set arithmetic over
/// whatever id type the caller already has (`QueueItem.id`, a `UUID`, in this app) rather than over
/// the queue type itself — `QueueItem` lives in…
public enum DJQueueBookkeeping {
    /// What a DJ's deactivation removes.
    public static func idsToRemoveOnDeactivation<ID: Hashable>(
        authoredIDs: Set<ID>, playedIDs: Set<ID>
    ) -> Set<ID> {
        authoredIDs.subtracting(playedIDs)
    }

    /// Manual edits win: once the user removes a DJ-added track, that exact track never comes back
    /// this session, even though the DJ has no memory of *why* it is not allowed to suggest it
    /// again — only that it is not.
    public static func manuallyExcluded<TrackID: Hashable>(
        removedAuthoredTrackIDs: some Sequence<TrackID>, into existing: Set<TrackID>
    ) -> Set<TrackID> {
        existing.union(removedAuthoredTrackIDs)
    }
}
