import Foundation
import PleviDomain

extension Error {
    /// Whether this is the shape a cancelled request comes back as.
    var isCancelledFetch: Bool {
        FetchCancellation.isCancelled(self)
    }
}
