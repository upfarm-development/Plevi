import Foundation
import PleviDomain

/// A transport for hosts the app has no `ServerConfig` for — during Plex sign-in, everything
/// happens against plex.tv before any server is known.
public struct PlainHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.malformedResponse(details: "non-HTTP response")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            throw ProviderError.network(underlying: error)
        }
    }
}
