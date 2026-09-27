import Foundation

/// URLProtocol stub: records each request (with its body) and answers with a canned response.
final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    struct Reply {
        let status: Int
        let json: String
        /// Seconds to wait before answering (simulates a slow server).
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply(status: 500, json: "{}")
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func respond(status: Int, json: String, delay: TimeInterval = 0) {
        lock.withLock {
            reply = Reply(status: status, json: json, delay: delay)
            recorded = []
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let current = Self.lock.withLock { () -> Reply in
            Self.recorded.append(Recorded(request: request, body: body))
            return Self.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: current.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        let delivery = Delivery(stub: self, response: response, data: Data(current.json.utf8))
        if current.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + current.delay) { delivery.run() }
        } else {
            delivery.run()
        }
    }

    private let stopLock = NSLock()
    private var stopped = false
    fileprivate var isStopped: Bool { stopLock.withLock { stopped } }

    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Hands a canned reply to the URL loading system, possibly later on another queue; nothing is
/// delivered once the request was stopped (e.g. cancelled by a client-side timeout).
private final class Delivery: @unchecked Sendable {
    private let stub: StubURLProtocol
    private let response: HTTPURLResponse
    private let data: Data

    init(stub: StubURLProtocol, response: HTTPURLResponse, data: Data) {
        self.stub = stub
        self.response = response
        self.data = data
    }

    func run() {
        guard !stub.isStopped else { return }
        stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
        stub.client?.urlProtocol(stub, didLoad: data)
        stub.client?.urlProtocolDidFinishLoading(stub)
    }
}
