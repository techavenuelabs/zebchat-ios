import Foundation
@testable import ZebChat

/// In-memory `SecureStore` (the Keychain is not used in unit tests).
final class MemoryStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}

/// Answers URLSession requests from a test handler and records them.
final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let method: String
        let path: String
        let authorization: String?
        let json: [String: Any]?
    }

    enum Reply {
        case json(Int, [String: Any])
        case raw(Int, String)
        case status(Int)
        case offline
    }

    typealias Handler = (Recorded) -> Reply

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [Recorded] = []

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func requests(to suffix: String) -> [Recorded] {
        requests.filter { $0.path.hasSuffix(suffix) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.body(of: request)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            json: json
        )
        Self.lock.lock()
        Self.recorded.append(entry)
        let handler = Self.handler
        Self.lock.unlock()

        switch handler?(entry) ?? .status(500) {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case let .json(status, object):
            respond(status, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        case let .raw(status, text):
            respond(status, Data(text.utf8))
        case let .status(status):
            respond(status, Data())
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands bodies to protocols as a stream.
    private static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

enum Fixtures {
    static let siteKey = "zc_test_site"
    static let appId = "com.example.app"
    static let visitorKey = "vk_0123456789abcdefghij"
    static let apiBase = URL(string: "https://api.test/api/v1")!

    static let app = AppInfo(
        appId: appId,
        sdk: "ios/1.0.0",
        client: MobileClientInfo(
            appId: appId,
            appVersion: "2.1",
            sdk: "ios/1.0.0",
            osVersion: "17.4",
            deviceModel: "iPhone15,2",
            deviceType: .phone
        )
    )

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A `WidgetSession` response body.
    static func session(
        token: String,
        visitorId: String,
        visitorKey: String? = nil,
        verified: Bool = false,
        expiresIn: TimeInterval = 12 * 3600
    ) -> [String: Any] {
        var body: [String: Any] = [
            "visitorToken": token,
            "visitorTokenExpiresAt": iso(Date().addingTimeInterval(expiresIn)),
            "visitor": [
                "id": visitorId,
                "name": "Visitor",
                "email": NSNull(),
                "phone": NSNull(),
                "verified": verified,
            ] as [String: Any],
            "availability": ["online": true, "reason": NSNull(), "nextOpenAt": NSNull(), "faces": [Any]()] as [String: Any],
        ]
        if let visitorKey { body["visitorKey"] = visitorKey }
        return body
    }

    static func visitor(_ id: String) -> ZebChatVisitor {
        ZebChatVisitor(id: id, name: "Visitor", email: nil, phone: nil, verified: false)
    }

    static func makeClient(
        store: MemoryStore = MemoryStore(),
        unread: UnreadCenter = UnreadCenter()
    ) -> ZebChatClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ZebChatClient(
            siteKey: siteKey,
            options: ZebChatOptions(apiBaseURL: apiBase),
            app: app,
            store: store,
            urlSession: URLSession(configuration: configuration),
            unread: unread
        )
    }
}
