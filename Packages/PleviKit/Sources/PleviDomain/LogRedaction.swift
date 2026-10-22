import Foundation

/// Scrubs credentials out of text that is about to be logged.
public enum LogRedaction {
    /// Query parameter names whose values are always masked (case-insensitive).
    /// `Redactor.sensitiveQueryKeys` is this set.
    public static let sensitiveQueryKeys: Set<String> = [
        "p", "t", "s", "u",           // Subsonic password/token/salt/user
        "apikey", "api_key",
        "password", "token", "auth", "jwt",
        "x-plex-token",
    ]

    public static let mask = "\u{2022}\u{2022}\u{2022}"

    // The key must follow `?` or `&` (or their percent-encoded forms), so a
    // value like `requests=5` or `subset=1` is not mistaken for `s=` or `t=`.
    private static let keyAlternation = sensitiveQueryKeys
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .sorted { $0.count > $1.count }
        .joined(separator: "|")

    private static let queryValue = try! NSRegularExpression(
        pattern: "(?<=[?&])(\(keyAlternation))=[^&\\s,)}\"'#]*",
        options: [.caseInsensitive]
    )
    /// The same, inside a URL that was itself percent-encoded into another
    /// URL's query (`%3Ft%3Dsecret%26s%3Dsalt`).
    private static let encodedQueryValue = try! NSRegularExpression(
        pattern: "(?<=%3F|%26)(\(keyAlternation))%3D(?:(?!%26)[^&\\s,)}\"'#])*",
        options: [.caseInsensitive]
    )
    /// `https://user:password@host`.
    private static let userInfo = try! NSRegularExpression(
        pattern: "(?<=://)[^/\\s@?#]+@",
        options: []
    )
    /// A header printed as text: `X-Plex-Token: abc`, `Authorization = Bearer abc`.
    private static let header = try! NSRegularExpression(
        pattern: "(?i)\\b(x-plex-token|x-api-key|authorization|cookie)\"?\\s*[:=]\\s*\"?[^\\n,;\"'&)}]*",
        options: []
    )

    /// `text` with every credential value replaced by a mask.
    public static func scrub(_ text: String) -> String {
        var result = text
        result = replace(queryValue, in: result) { "\($0)=\(mask)" }
        result = replace(encodedQueryValue, in: result) { "\($0)%3D\(mask)" }
        result = replace(userInfo, in: result) { _ in "\(mask)@" }
        result = replace(header, in: result) { "\($0): \(mask)" }
        return result
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with template: (String) -> String
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let keyRange = match.numberOfRanges > 1 ? match.range(at: 1) : NSRange(location: NSNotFound, length: 0)
            let key = keyRange.location == NSNotFound ? "" : ns.substring(with: keyRange)
            result += template(key)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// A one-line, credential-free account of what went wrong: the sentence,
    /// the code that names it, and where it happened — never the raw error,
    /// whose default description dumps `userInfo` including the failing URL.
    public static func describe(_ error: any Error) -> String {
        if let error = error as? ProviderError { return error.description }
        if let error = error as? URLError { return describe(error) }
        if error is CancellationError { return "cancelled" }
        return scrub("\(error)")
    }

    public static func describe(_ error: URLError) -> String {
        var text = "URLError \(error.code.rawValue)"
        if let failing = error.failingURL?.absoluteString
            ?? error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            text += " for \(scrub(failing))"
        }
        return text
    }
}

extension ProviderError: CustomStringConvertible {
    /// Safe to interpolate into a log: never carries a query value, a token
    /// or a URL's userinfo. `errorDescription` is the sentence for people;
    /// this one names the case, for whoever reads the log.
    public var description: String {
        switch self {
        case .notAuthenticated(let failure):
            "notAuthenticated(\(failure))"
        case .notAuthorized:
            "notAuthorized"
        case .notFound:
            "notFound"
        case .missingParameter(let name):
            "missingParameter(\(LogRedaction.scrub(name)))"
        case .incompatibleServer(let details):
            "incompatibleServer(\(LogRedaction.scrub(details ?? "")))"
        case .serverError(let code, let message, let helpURL):
            "serverError(code: \(code.map(String.init) ?? "nil"), message: \(LogRedaction.scrub(message ?? "")), help: \(LogRedaction.scrub(helpURL?.absoluteString ?? "")))"
        case .malformedResponse(let details):
            "malformedResponse(\(LogRedaction.scrub(details)))"
        case .proxySignInRequired(let url):
            "proxySignInRequired(\(LogRedaction.scrub(url.absoluteString)))"
        case .network(let underlying):
            "network(\(LogRedaction.describe(underlying)))"
        case .tls(let failure):
            "tls(\(failure))"
        case .unsupportedOperation:
            "unsupportedOperation"
        case .conflict(let details):
            "conflict(\(LogRedaction.scrub(details)))"
        }
    }
}
