import Foundation
import Network

enum ExporterError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    var description: String {
        switch self {
        case let .invalidPort(port): "not a valid TCP port: \(port)"
        }
    }
}

/// A minimal HTTP server for one route: GET /metrics.
///
/// A whole web framework is a lot for one read-only endpoint, so this is an
/// NWListener and a hand-written response line. The routing is a pure static
/// function so it can be tested without binding a socket.
final class MetricsServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: @Sendable () -> String
    private let queue = DispatchQueue(label: "wtf.evan.monitor.exporter.server")
    private let portLock = NSLock()
    private var resolvedPort: UInt16?

    init(host: String, port: UInt16, body: @escaping @Sendable () -> String) throws {
        self.body = body
        guard let nwPort = NWEndpoint.Port(rawValue: port)
        else { throw ExporterError.invalidPort(port) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        listener = try NWListener(using: parameters)
    }

    /// The bound port once the listener is ready; nil before then. Read only on
    /// `.ready`, because before then `listener.port` reports the requested port
    /// — 0 for an ephemeral bind, which is not a port anything can connect to.
    var port: UInt16? {
        portLock.lock()
        defer { portLock.unlock() }
        return resolvedPort
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state,
                  let bound = listener.port?.rawValue else { return }
            portLock.lock()
            resolvedPort = bound
            portLock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection
            .receive(minimumIncompleteLength: 1,
                     maximumLength: 65536)
            { [weak self] data, _, _, _ in
                guard let self else {
                    connection.cancel()
                    return
                }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let response = MetricsServer.route(request: request, body: body)
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
    }

    /// Route one request line. GET /metrics (optionally with a query) is 200;
    /// everything else is 404.
    static func route(request: String, body: () -> String) -> String {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let tokens = requestLine.split(separator: " ")
        let method = tokens.first.map(String.init) ?? ""
        let path = tokens.count >= 2 ? String(tokens[1]) : ""
        let isMetrics = method == "GET" && (path == "/metrics" || path.hasPrefix("/metrics?"))
        if isMetrics {
            return httpResponse(
                status: "200 OK",
                contentType: "text/plain; version=0.0.4; charset=utf-8",
                body: body()
            )
        }
        return httpResponse(
            status: "404 Not Found",
            contentType: "text/plain; charset=utf-8",
            body: "not found\n"
        )
    }

    private static func httpResponse(status: String, contentType: String,
                                     body: String) -> String
    {
        let length = Data(body.utf8).count
        return "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(length)\r\n"
            + "Connection: close\r\n\r\n"
            + body
    }
}
