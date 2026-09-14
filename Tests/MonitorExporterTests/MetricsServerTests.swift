import Foundation
@testable import MonitorExporter
import Testing

@Suite("Metrics server")
struct MetricsServerTests {
    @Test("GET /metrics returns 200 with the Prometheus content type and body")
    func metricsRoute() {
        let response = MetricsServer
            .route(request: "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n") { "BODY\n" }
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Type: text/plain; version=0.0.4; charset=utf-8"))
        #expect(response.hasSuffix("\r\n\r\nBODY\n"))
    }

    @Test("a metrics request with a query string still matches")
    func metricsWithQuery() {
        #expect(MetricsServer.route(request: "GET /metrics?x=1 HTTP/1.1\r\n\r\n") { "B" }
            .hasPrefix("HTTP/1.1 200"))
    }

    @Test("any other path is a 404", arguments: [
        "GET / HTTP/1.1\r\n\r\n",
        "POST /metrics HTTP/1.1\r\n\r\n",
        "GET /healthz HTTP/1.1\r\n\r\n",
    ])
    func notFound(_ request: String) {
        #expect(MetricsServer.route(request: request) { "B" }
            .hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test("a running server answers a real scrape on its bound port")
    func realScrape() async throws {
        let server = try MetricsServer(host: "127.0.0.1", port: 0) { "# TYPE x gauge\nx 1\n" }
        server.start()
        defer { server.stop() }

        var port: UInt16?
        for _ in 0..<100 where port == nil {
            port = server.port
            if port == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let bound = try #require(port)
        let (data, response) = try await URLSession.shared
            .data(from: #require(URL(string: "http://127.0.0.1:\(bound)/metrics")))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("x 1") == true)
    }
}
