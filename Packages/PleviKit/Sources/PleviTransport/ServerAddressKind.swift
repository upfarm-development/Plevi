import Foundation

/// Whether an address can be reached from anywhere, or only from the network the server sits on.
public enum ServerAddressKind: Sendable, Hashable {
    /// Reachable only from the network the server is on — what
    /// `EndpointValidation.isPrivateHost` already means by private.
    case onYourNetwork
    /// An address written out, and not a private one.
    case fromAnywhere
    /// A name that gives nothing away.
    case unknown

    /// What to call it on screen, or nil where the host said nothing and the
    /// slot's own name is the best there is.
    public var label: String? {
        switch self {
        case .onYourNetwork: "Local"
        case .fromAnywhere: "Remote"
        case .unknown: nil
        }
    }

    /// Reads the host, and nothing else: no lookup, no network, and no
    /// guessing from which slot it arrived in.
    public init(host: String) {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { self = .unknown; return }
        if EndpointValidation.isPrivateHost(host) {
            self = .onYourNetwork
        } else if EndpointValidation.literalIPv4(of: host) != nil || host.contains(":") {
            // An address spelled out, and not one of the private ranges: the
            // only case where "reachable from anywhere" can be said without
            // asking anybody.
            self = .fromAnywhere
        } else {
            self = .unknown
        }
    }
}

public extension ServerAddresses {
    /// Whether reaching this server can involve the local network: either address is a private one
    /// or a `.local` name.
    var mayNeedLocalNetworkAccess: Bool {
        inPreferenceOrder.contains { $0.addressKind == .onYourNetwork }
    }
}

public extension URL {
    /// What this address is, as far as its host will say. See
    /// `ServerAddressKind`.
    var addressKind: ServerAddressKind {
        ServerAddressKind(host: host() ?? "")
    }
}
