import Foundation
import Network

/// A tiny HTTP/1.1 server on the loopback interface, for driving the real `BackgroundDownloader`
/// through the responses a music server gives when it is under stress: an error dressed as a
/// success, a body cut short, a body with no length.
final class StressLoopbackServer: @unchecked Sendable {
    enum Route {
        /// A complete response with a Content-Length.
        case full(status: Int, contentType: String, body: Data)
        /// Advertises `advertised` bytes, sends `sent`, then drops the connection.
        case truncated(contentType: String, advertised: Int, sent: Int)
        /// No Content-Length, `Connection: close`, body ends when the socket does.
        case closeDelimited(contentType: String, body: Data)
        /// Chunked encoding, one chunk, then the socket is dropped with no
        /// terminating zero-length chunk.
        case chunkedCut(contentType: String, body: Data)
        /// Accepts the request and then says nothing, ever — a server that is
        /// busy, or a connection the phone thinks is up and is not.
        case hold
        /// A 302 to somewhere else.
        case redirect(location: String)
        /// Answers 200 after `delay` seconds, then a full body.
        case slow(delay: Double, contentType: String, body: Data)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "StressLoopbackServer")
    private var routes: [String: Route] = [:]
    private var hits: [String: Int] = [:]
    private var held: [NWConnection] = []
    private var heads: [String: String] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    func route(_ path: String, _ route: Route) {
        lock.withLock { routes[path] = route }
    }

    func hitCount(_ path: String) -> Int {
        lock.withLock { hits[path] ?? 0 }
    }

    /// The request line and headers of the most recent request for `path`.
    func lastRequestHead(_ path: String) -> String? {
        lock.withLock { heads[path] }
    }

    /// Resumes a continuation at most once, whichever state callback gets there first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        func arm(_ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
        }
        func finish(_ result: Result<Void, Error>) {
            let taken = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { continuation = nil }
                return continuation
            }
            taken?.resume(with: result)
        }
    }

    func start() async throws {
        let gate = Gate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.arm(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    gate.finish(.success(()))
                case .failed(let error):
                    gate.finish(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        let connections = lock.withLock { () -> [NWConnection] in
            defer { held = [] }
            return held
        }
        for connection in connections { connection.cancel() }
    }

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?").first ?? "" : ""
            let route: Route? = self.lock.withLock {
                self.hits[path, default: 0] += 1
                self.heads[path] = text
                return self.routes[path]
            }
            guard let route else {
                self.send(connection, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: Data(), thenClose: true)
                return
            }
            switch route {
            case .full(let status, let type, let body):
                let head = "HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                self.send(connection, head: head, body: body, thenClose: true)
            case .truncated(let type, let advertised, let sent):
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(advertised)\r\nConnection: close\r\n\r\n"
                self.send(connection, head: head, body: Data(repeating: 0x41, count: sent), thenClose: true)
            case .closeDelimited(let type, let body):
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nConnection: close\r\n\r\n"
                self.send(connection, head: head, body: body, thenClose: true)
            case .hold:
                self.lock.withLock { self.held.append(connection) }
            case .redirect(let location):
                let head = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                self.send(connection, head: head, body: Data(), thenClose: true)
            case .slow(let delay, let type, let body):
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.send(connection, head: head, body: body, thenClose: true)
                }
            case .chunkedCut(let type, let body):
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                var chunk = Data(String(body.count, radix: 16).utf8)
                chunk.append(Data("\r\n".utf8))
                chunk.append(body)
                chunk.append(Data("\r\n".utf8))
                self.send(connection, head: head, body: chunk, thenClose: true)
            }
        }
    }

    private func send(_ connection: NWConnection, head: String, body: Data, thenClose: Bool) {
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            if thenClose { connection.cancel() }
        })
    }
}
