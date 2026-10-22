import Foundation
import Testing
@testable import PleviDomain

@Suite("What an error says when the point is to work out what went wrong")
struct ProviderErrorDiagnosticTests {
    @Test("A network failure carries the code that names it")
    func aNetworkFailureCarriesItsCode() {
        let error = ProviderError.network(underlying: URLError(.secureConnectionFailed))
        let said = error.diagnosticDescription
        #expect(said.contains("\(URLError.Code.secureConnectionFailed.rawValue)"))
        // The sentence is still there. The number is an addition, not a
        // replacement: whoever reads this is often the listener, not a
        // developer.
        #expect(said.hasPrefix(URLError(.secureConnectionFailed).localizedDescription))
    }

    @Test("Two different TLS failures read differently")
    func twoTLSFailuresReadDifferently() {
        // The whole reason this exists.
        let refused = ProviderError.network(underlying: URLError(.secureConnectionFailed))
        let untrusted = ProviderError.network(underlying: URLError(.serverCertificateUntrusted))
        #expect(refused.diagnosticDescription != untrusted.diagnosticDescription)
    }

    @Test("Everything else says exactly what it always said")
    func everythingElseIsUnchanged() {
        let error = ProviderError.notFound
        #expect(error.diagnosticDescription == error.errorDescription)
    }

    @Test("The connection failing is told apart from the server declining")
    func transportFailuresAreTheirOwnKind() {
        #expect(ProviderError.network(underlying: URLError(.timedOut)).isTransportFailure)
        #expect(ProviderError.tls(.clientCertificateRejected).isTransportFailure)
        // A server that answered — however unwelcomely — answered. Asking it
        // something else is worth a try; asking a connection that could not
        // be made is not.
        #expect(!ProviderError.notFound.isTransportFailure)
        #expect(!ProviderError.serverError(code: 500, message: nil, helpURL: nil).isTransportFailure)
    }
}
