import Foundation
import PleviDomain

/// Produces log- and diagnostics-safe descriptions of URLs and requests.
public enum Redactor {
    /// Query parameter names whose values are always masked (case-insensitive).
    public static let sensitiveQueryKeys: Set<String> = LogRedaction.sensitiveQueryKeys

    /// Header names whose values are always masked (case-insensitive).
    public static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "cookie", "set-cookie",
        "cf-access-client-secret",
        "x-plex-token",
        "x-api-key",
    ]

    private static let mask = "\u{2022}\u{2022}\u{2022}"

    public static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<unparseable url>"
        }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                sensitiveQueryKeys.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: mask)
                    : item
            }
        }
        components.user = nil
        components.password = nil
        return components.string ?? "<unparseable url>"
    }

    public static func redacted(_ request: URLRequest) -> String {
        var lines = [String]()
        let method = request.httpMethod ?? "GET"
        let url = request.url.map(redacted(_:)) ?? "<no url>"
        lines.append("\(method) \(url)")
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let shown = sensitiveHeaderNames.contains(name.lowercased()) ? mask : value
            lines.append("\(name): \(shown)")
        }
        return lines.joined(separator: "\n")
    }
}
