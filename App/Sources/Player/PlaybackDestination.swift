import Foundation

/// Where a queue starter sends its queue.
enum PlaybackDestination: Equatable {
    case here
    /// The peer's fingerprint.
    case device(RemoteDeviceID)
}

/// A paired device's identity, stable for as long as its key is — the same
/// fingerprint `PleviRemote.PeerPin` and `PleviRemote.DeviceList` key on.
struct RemoteDeviceID: Hashable, Sendable {
    let fingerprint: Data
}

extension AppModel {
    /// `.device` while this device is controlling another — read
    /// synchronously off `remote`'s own published state, not cached, per this file's own header
    /// note on why every queue starter reads it fresh at its own first…
    var playbackDestination: PlaybackDestination {
        guard let fingerprint = remote.controllingPeerFingerprint else { return .here }
        return .device(RemoteDeviceID(fingerprint: fingerprint))
    }

    /// The player a queue starter should send to — `nil` for a destination that named a device this
    /// device is no longer controlling.
    func player(for destination: PlaybackDestination) -> (any PlaybackControlling)? {
        switch destination {
        case .here:
            return player
        case .device(let id):
            guard let controlled = remote.controlledPlayer, remote.controllingPeerFingerprint == id.fingerprint else {
                return nil
            }
            return controlled
        }
    }
}
