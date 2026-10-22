import Foundation
import Network
import Synchronization

/// Whether the connection in use costs money by the megabyte.
final class NetworkPathMonitor: Sendable {
    /// A box of its own, so the update handler can hold it without holding
    /// the monitor — a `Mutex` cannot be copied out of `self`.
    private final class State: Sendable {
        let expensive = Mutex(false)
        /// Told when the answer changes, so work held back for a cheaper
        /// connection can start the moment one arrives rather than on the
        /// next time something happens to ask.
        let listeners = Mutex<[Int: @Sendable (Bool) -> Void]>([:])
        let nextListener = Mutex(0)
        /// What the connection looked like the last time anyone was told — which interfaces it uses
        /// and whether anything is reachable at all.
        let signature = Mutex<String?>(nil)
        let pathListeners = Mutex<[Int: @Sendable (Bool) -> Void]>([:])
        /// Whether anything can be reached at all, as of the last update.
        /// True until the first update: no news is not bad news.
        let satisfied = Mutex(true)
    }

    private let state = State()
    private let monitor = NWPathMonitor()

    /// Cellular, or a personal hotspot — anything the system counts as
    /// expensive. Broader than "cellular" on purpose: tethering off a phone
    /// costs the same either way.
    var isExpensive: Bool {
        state.expensive.withLock { $0 }
    }

    /// Called whenever the answer changes, and only then.
    @discardableResult
    func onChange(_ handler: @escaping @Sendable (Bool) -> Void) -> Int {
        let token = state.nextListener.withLock { next -> Int in
            next += 1
            return next
        }
        state.listeners.withLock { $0[token] = handler }
        return token
    }

    func removeOnChange(_ token: Int) {
        state.listeners.withLock { $0[token] = nil }
    }

    /// Called when the *shape* of the connection changes — Wi-Fi to cellular, either one dropping
    /// out, one coming back — with whether anything can be reached at all.
    @discardableResult
    func onPathChange(_ handler: @escaping @Sendable (Bool) -> Void) -> Int {
        let token = state.nextListener.withLock { next -> Int in
            next += 1
            return next
        }
        state.pathListeners.withLock { $0[token] = handler }
        return token
    }

    func removeOnPathChange(_ token: Int) {
        state.pathListeners.withLock { $0[token] = nil }
    }

    /// Whether the phone has a usable connection of any kind right now.
    /// Distinct from `isExpensive`: a transfer that has gone quiet in a lift
    /// is waiting, not stuck.
    var isSatisfied: Bool {
        state.satisfied.withLock { $0 }
    }

    init() {
        // Formed outside any actor: the handler runs on the monitor's own
        // queue, and a closure that captured main-actor state would be a data
        // race the compiler is right to refuse.
        let state = self.state
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            state.satisfied.withLock { $0 = satisfied }
            let interfaces = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
                .filter { path.usesInterfaceType($0) }
                .map { String(describing: $0) }
                .joined(separator: ",")
            let signature = "\(satisfied)|\(interfaces)"
            let shapeChanged = state.signature.withLock { held -> Bool in
                let first = held == nil
                guard held != signature else { return false }
                held = signature
                return !first
            }
            if shapeChanged {
                for tell in state.pathListeners.withLock({ Array($0.values) }) { tell(satisfied) }
            }
            let now = path.isExpensive || path.usesInterfaceType(.cellular)
            let changed = state.expensive.withLock { held -> Bool in
                guard held != now else { return false }
                held = now
                return true
            }
            guard changed else { return }
            for tell in state.listeners.withLock({ Array($0.values) }) { tell(now) }
        }
        monitor.start(queue: DispatchQueue(label: "network.path"))
    }
}
