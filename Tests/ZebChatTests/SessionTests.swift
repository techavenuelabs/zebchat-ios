import XCTest
@testable import ZebChat

private enum Path {
    static let sessions = "/api/v1/widget/sessions"
    static let identify = "/api/v1/widget/identify"
    static let devices = "/api/v1/widget/devices"
    static let pageviews = "/api/v1/widget/pageviews"
    static let current = "/api/v1/widget/conversations/current"
}

/// The session model and HTTP client against a stubbed API (docs/MOBILE_SDK.md §5).
final class SessionTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Sessions

    func testCreatesAnAppSessionAndKeepsTheVisitorKey() async throws {
        let store = MemoryStore()
        StubURLProtocol.install { request in
            request.path == Path.sessions
                ? .json(201, Fixtures.session(token: "t1", visitorId: "vis_a", visitorKey: Fixtures.visitorKey))
                : .status(404)
        }
        let client = Fixtures.makeClient(store: store)

        let session = try await client.sessionForChat(forceNew: false).value.get()

        XCTAssertEqual(session.token, "t1")
        XCTAssertEqual(session.visitor.id, "vis_a")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertNil(request.authorization)
        XCTAssertEqual(request.json?["siteKey"] as? String, Fixtures.siteKey)
        XCTAssertEqual(request.json?["app"] as? String, Fixtures.appId)
        XCTAssertEqual(request.json?["platform"] as? String, "ios")
        XCTAssertNil(request.json?["host"])
        XCTAssertNil(request.json?["visitorKey"])
        XCTAssertEqual(SDKState(store: store).visitorKey, Fixtures.visitorKey)

        // Cached until shortly before expiry: no second request.
        _ = try await client.sessionForChat(forceNew: false).value.get()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testColdStartReusesTheCachedSession() async throws {
        let store = MemoryStore()
        let state = SDKState(store: store)
        state.visitorKey = Fixtures.visitorKey
        state.session = StoredSession(
            token: "cached",
            expiresAt: Fixtures.iso(Date().addingTimeInterval(6 * 3600)),
            visitor: Fixtures.visitor("vis_a"),
            user: nil
        )
        StubURLProtocol.install { _ in .status(500) }

        let session = try await Fixtures.makeClient(store: store).sessionForChat(forceNew: false).value.get()

        XCTAssertEqual(session.token, "cached")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testExpiredSessionIsRecreatedWithTheStoredVisitorKey() async throws {
        let store = MemoryStore()
        let state = SDKState(store: store)
        state.visitorKey = Fixtures.visitorKey
        state.session = StoredSession(
            token: "old",
            expiresAt: Fixtures.iso(Date().addingTimeInterval(60)),
            visitor: Fixtures.visitor("vis_a"),
            user: nil
        )
        StubURLProtocol.install { request in
            request.path == Path.sessions ? .json(201, Fixtures.session(token: "new", visitorId: "vis_a")) : .status(404)
        }

        let session = try await Fixtures.makeClient(store: store).sessionForChat(forceNew: false).value.get()

        XCTAssertEqual(session.token, "new")
        XCTAssertEqual(StubURLProtocol.requests.first?.json?["visitorKey"] as? String, Fixtures.visitorKey)
        XCTAssertEqual(state.visitorKey, Fixtures.visitorKey, "an existing key is kept when none is returned")
        XCTAssertEqual(state.session?.token, "new")
    }

    func testRefusedSessionIsReportedToTheChat() async {
        StubURLProtocol.install { _ in .status(403) }
        let result = await Fixtures.makeClient().sessionForChat(forceNew: false).value
        XCTAssertEqual(result, .failure(.http(status: 403)))
    }

    func testOfflineIsANetworkError() async {
        StubURLProtocol.install { _ in .offline }
        let result = await Fixtures.makeClient().sessionForChat(forceNew: false).value
        XCTAssertEqual(result, .failure(.network))
    }

    func testMalformedSessionIsRejected() async {
        StubURLProtocol.install { _ in .json(201, ["visitorToken": "", "visitor": ["id": "v"]]) }
        let result = await Fixtures.makeClient().sessionForChat(forceNew: false).value
        XCTAssertEqual(result, .failure(.invalidResponse))
    }

    // MARK: - Identify

    func testUserSetBeforeTheFirstSessionIsIdentifiedRightAway() async throws {
        let store = MemoryStore()
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "anon", visitorId: "vis_anon", visitorKey: Fixtures.visitorKey))
            case Path.identify: return .json(200, Fixtures.session(token: "known", visitorId: "vis_known", verified: true))
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient(store: store)
        let user = ZebChatUser(id: "42", email: "a@b.com", name: "Ana", hash: "abc")

        await client.setUser(user).value
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "no session is created just for setUser")
        let session = try await client.sessionForChat(forceNew: false).value.get()

        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Path.sessions, Path.identify])
        let identifyRequest = StubURLProtocol.requests[1]
        XCTAssertEqual(identifyRequest.authorization, "Bearer anon")
        XCTAssertEqual(identifyRequest.json?["id"] as? String, "42")
        XCTAssertEqual(identifyRequest.json?["hash"] as? String, "abc")
        XCTAssertEqual(identifyRequest.json?["email"] as? String, "a@b.com")
        XCTAssertNil(identifyRequest.json?["phone"])
        XCTAssertEqual(session.visitor.id, "vis_known")
        XCTAssertEqual(session.token, "known")
        XCTAssertEqual(session.user, user)
    }

    func testIdentityBodyMatchesAndroid() throws {
        func encoded(_ user: ZebChatUser) throws -> [String: String] {
            let data = try JSONEncoder().encode(APIClient.IdentityBody(user))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        }
        // Verified: id + hash, details trimmed.
        XCTAssertEqual(
            try encoded(ZebChatUser(id: "42", email: " a@b.com ", name: "Ana", hash: "abc")),
            ["id": "42", "hash": "abc", "email": "a@b.com", "name": "Ana"]
        )
        // An id without its hash (or the reverse) is dropped; the profile is still sent.
        XCTAssertEqual(
            try encoded(ZebChatUser(id: "42", email: "a@b.com", name: "Ana", phone: "+1 555")),
            ["email": "a@b.com", "name": "Ana", "phone": "+1 555"]
        )
        XCTAssertEqual(try encoded(ZebChatUser(name: "Ana", hash: "abc")), ["name": "Ana"])
        // Empty strings are left out (an empty id counts as no id).
        XCTAssertEqual(
            try encoded(ZebChatUser(id: "", email: "  ", name: "", phone: "", hash: "abc")),
            [:]
        )
    }

    func testUnverifiedUserSendsTheProfileWithoutTheId() async throws {
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "anon", visitorId: "vis_anon", visitorKey: Fixtures.visitorKey))
            case Path.identify: return .json(200, Fixtures.session(token: "named", visitorId: "vis_anon"))
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient()
        await client.setUser(ZebChatUser(id: "42", email: " a@b.com ", name: "", phone: "+1 555")).value

        _ = try await client.sessionForChat(forceNew: false).value.get()
        let identifyRequest = try XCTUnwrap(StubURLProtocol.requests(to: "/widget/identify").first)
        XCTAssertNil(identifyRequest.json?["id"])
        XCTAssertNil(identifyRequest.json?["hash"])
        XCTAssertNil(identifyRequest.json?["name"])
        XCTAssertEqual(identifyRequest.json?["email"] as? String, "a@b.com")
        XCTAssertEqual(identifyRequest.json?["phone"] as? String, "+1 555")
    }

    func testIdentifyAdoptsAnotherVisitorAndRePostsThePushToken() async throws {
        let store = MemoryStore()
        StubURLProtocol.install { request in
            switch (request.method, request.path) {
            case ("POST", Path.sessions): return .json(201, Fixtures.session(token: "anon", visitorId: "vis_anon", visitorKey: Fixtures.visitorKey))
            case ("POST", Path.identify): return .json(200, Fixtures.session(token: "known", visitorId: "vis_known", verified: true))
            case ("POST", Path.devices): return .status(204)
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient(store: store)

        await client.setPushToken("fcm-1").value
        await client.setUser(ZebChatUser(id: "42", hash: "abc")).value

        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Path.sessions, Path.devices, Path.identify, Path.devices])
        let registrations = StubURLProtocol.requests(to: "/widget/devices")
        XCTAssertEqual(registrations.map(\.authorization), ["Bearer anon", "Bearer known"])
        XCTAssertEqual(registrations.last?.json?["token"] as? String, "fcm-1")
        XCTAssertEqual(registrations.last?.json?["platform"] as? String, "ios")
        XCTAssertEqual(registrations.last?.json?["appId"] as? String, Fixtures.appId)
        XCTAssertEqual(StubURLProtocol.requests(to: "/widget/identify").first?.authorization, "Bearer anon")
        let snapshot = await client.snapshot().value
        XCTAssertEqual(snapshot.session?.visitor.id, "vis_known")
        XCTAssertEqual(SDKState(store: store).registeredDevice, RegisteredDevice(token: "fcm-1", visitorId: "vis_known"))
    }

    func testSamePushTokenIsNotRegisteredTwice() async {
        StubURLProtocol.install { request in
            request.path == Path.sessions ? .json(201, Fixtures.session(token: "t", visitorId: "v", visitorKey: Fixtures.visitorKey)) : .status(204)
        }
        let client = Fixtures.makeClient()
        await client.setPushToken("fcm-1").value
        await client.setPushToken("fcm-1").value
        XCTAssertEqual(StubURLProtocol.requests(to: "/widget/devices").count, 1)
    }

    func testRotatedPushTokenDeletesTheOldOneWithARenewedSessionOn401() async throws {
        let store = MemoryStore()
        let sessionsCreated = Locked(0)
        StubURLProtocol.install { request in
            switch (request.method, request.path) {
            case ("POST", Path.sessions):
                let count = sessionsCreated.update { value -> Int in
                    value += 1
                    return value
                }
                return .json(201, Fixtures.session(token: "t\(count)", visitorId: "vis_a", visitorKey: Fixtures.visitorKey))
            case ("DELETE", Path.devices):
                return request.authorization == "Bearer t1" ? .status(401) : .status(204)
            case ("POST", Path.devices):
                return .status(204)
            default:
                return .status(404)
            }
        }
        let client = Fixtures.makeClient(store: store)
        await client.setPushToken("fcm-1").value

        await client.setPushToken("fcm-2").value

        let deletes = StubURLProtocol.requests(to: "/widget/devices").filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.map(\.authorization), ["Bearer t1", "Bearer t2"])
        XCTAssertEqual(deletes.last?.json?["token"] as? String, "fcm-1")
        let registration = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(registration.method, "POST")
        XCTAssertEqual(registration.path, Path.devices)
        XCTAssertEqual(registration.authorization, "Bearer t2")
        XCTAssertEqual(registration.json?["token"] as? String, "fcm-2")
        XCTAssertEqual(SDKState(store: store).registeredDevice, RegisteredDevice(token: "fcm-2", visitorId: "vis_a"))
    }

    func testRefusedIdentityKeepsTheAnonymousVisitor() async throws {
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "anon", visitorId: "vis_anon", visitorKey: Fixtures.visitorKey))
            case Path.identify: return .status(403)
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient()
        await client.setUser(ZebChatUser(id: "42", hash: "wrong")).value

        let session = try await client.sessionForChat(forceNew: false).value.get()
        XCTAssertEqual(session.visitor.id, "vis_anon")
        // Not retried on every call until the session expires.
        _ = try await client.sessionForChat(forceNew: false).value.get()
        XCTAssertEqual(StubURLProtocol.requests(to: "/widget/identify").count, 1)
    }

    // MARK: - Logout

    func testLogoutDeletesTheDeviceBeforeForgettingTheVisitor() async throws {
        let store = MemoryStore()
        let identityAtDelete = Locked<(key: String?, user: ZebChatUser?)?>(nil)
        StubURLProtocol.install { request in
            switch (request.method, request.path) {
            case ("POST", Path.sessions): return .json(201, Fixtures.session(token: "anon", visitorId: "vis_anon", visitorKey: Fixtures.visitorKey))
            case ("POST", Path.identify): return .json(200, Fixtures.session(token: "known", visitorId: "vis_known"))
            case ("POST", Path.devices): return .status(204)
            case ("DELETE", Path.devices):
                let state = SDKState(store: store)
                identityAtDelete.set((state.visitorKey, state.user))
                return .status(204)
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient(store: store)
        await client.setPushToken("fcm-1").value
        await client.setUser(ZebChatUser(id: "42", hash: "abc")).value

        await client.logout().value

        let delete = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(delete.method, "DELETE")
        XCTAssertEqual(delete.path, Path.devices)
        XCTAssertEqual(delete.authorization, "Bearer known")
        XCTAssertEqual(delete.json?["token"] as? String, "fcm-1")
        let atDelete = try XCTUnwrap(identityAtDelete.get())
        XCTAssertEqual(atDelete.key, Fixtures.visitorKey, "the key is still there while the device is deleted")
        XCTAssertEqual(atDelete.user?.id, "42")

        let state = SDKState(store: store)
        XCTAssertNil(state.visitorKey)
        XCTAssertNil(state.user)
        XCTAssertNil(state.session)
        XCTAssertNil(state.registeredDevice)
        XCTAssertEqual(state.pushToken, "fcm-1")

        // The next chat is a new anonymous visitor, and the push token follows it.
        _ = try await client.sessionForChat(forceNew: false).value.get()
        let next = StubURLProtocol.requests(to: "/widget/sessions").last
        XCTAssertNil(next?.json?["visitorKey"])
        XCTAssertEqual(StubURLProtocol.requests.last?.path, Path.devices)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "POST")
    }

    func testSigningInAsAnotherUserLogsTheFirstOneOut() async throws {
        let store = MemoryStore()
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "anon", visitorId: "vis_anon", visitorKey: Fixtures.visitorKey))
            case Path.identify: return .json(200, Fixtures.session(token: "known", visitorId: "vis_known"))
            default: return .status(204)
            }
        }
        let client = Fixtures.makeClient(store: store)
        await client.setPushToken("fcm-1").value
        await client.setUser(ZebChatUser(id: "42", hash: "a")).value

        await client.setUser(ZebChatUser(id: "43", hash: "b")).value

        XCTAssertEqual(StubURLProtocol.requests.last?.method, "DELETE")
        let state = SDKState(store: store)
        XCTAssertNil(state.visitorKey)
        XCTAssertEqual(state.user?.id, "43")
    }

    // MARK: - Screens

    func testScreenViewsCarryClientInfoAndAnAppURL() async throws {
        StubURLProtocol.install { request in
            request.path == Path.sessions ? .json(201, Fixtures.session(token: "t", visitorId: "v", visitorKey: Fixtures.visitorKey)) : .status(204)
        }
        let client = Fixtures.makeClient()

        await client.trackScreen("Checkout/Payment Details").value

        let pageview = try XCTUnwrap(StubURLProtocol.requests(to: "/widget/pageviews").first)
        XCTAssertEqual(pageview.authorization, "Bearer t")
        XCTAssertEqual(pageview.json?["url"] as? String, "app://com.example.app/Checkout/Payment%20Details")
        XCTAssertEqual(pageview.json?["title"] as? String, "Checkout/Payment Details")
        let info = try XCTUnwrap(pageview.json?["client"] as? [String: Any])
        XCTAssertEqual(info["platform"] as? String, "ios")
        XCTAssertEqual(info["appId"] as? String, Fixtures.appId)
        XCTAssertEqual(info["appVersion"] as? String, "2.1")
        XCTAssertEqual(info["sdk"] as? String, "ios/1.0.0")
        XCTAssertEqual(info["osVersion"] as? String, "17.4")
        XCTAssertEqual(info["deviceModel"] as? String, "iPhone15,2")
        XCTAssertEqual(info["deviceType"] as? String, "phone")
    }

    func testScreenViewsAreBufferedOfflineUpToTwenty() async {
        let online = Locked(false)
        StubURLProtocol.install { request in
            guard online.get() else { return .offline }
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "t", visitorId: "v", visitorKey: Fixtures.visitorKey))
            case Path.current: return .raw(200, "null")
            default: return .status(204)
            }
        }
        let client = Fixtures.makeClient()
        for index in 1 ... 25 {
            client.trackScreen("Screen \(index)")
        }
        await client.trackScreen("Screen 26").value

        let pending = await client.snapshot().value.pendingScreens
        XCTAssertEqual(pending.count, ZebChatClient.screenBufferMax)
        XCTAssertEqual(pending.first?.title, "Screen 7")
        XCTAssertEqual(pending.last?.title, "Screen 26")

        online.set(true)
        await client.refresh().value

        let sent = StubURLProtocol.requests(to: "/widget/pageviews").compactMap { $0.json?["title"] as? String }
        XCTAssertEqual(sent, (7 ... 26).map { "Screen \($0)" })
        let after = await client.snapshot().value.pendingScreens
        XCTAssertTrue(after.isEmpty)
    }

    func testRejectedTokenGetsOneRetryWithANewSession() async throws {
        let store = MemoryStore()
        let state = SDKState(store: store)
        state.visitorKey = Fixtures.visitorKey
        state.session = StoredSession(
            token: "revoked",
            expiresAt: Fixtures.iso(Date().addingTimeInterval(6 * 3600)),
            visitor: Fixtures.visitor("v"),
            user: nil
        )
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "fresh", visitorId: "v"))
            case Path.pageviews: return request.authorization == "Bearer revoked" ? .status(401) : .status(204)
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient(store: store)

        await client.trackScreen("Home").value

        XCTAssertEqual(
            StubURLProtocol.requests.map { "\($0.path) \($0.authorization ?? "-")" },
            ["\(Path.pageviews) Bearer revoked", "\(Path.sessions) -", "\(Path.pageviews) Bearer fresh"]
        )
        let pending = await client.snapshot().value.pendingScreens
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Unread

    func testUnreadCountReachesListenersOnTheMainThread() async {
        let unread = UnreadCenter()
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "t", visitorId: "v", visitorKey: Fixtures.visitorKey))
            case Path.current: return .json(200, ["id": "conv_1", "status": "open", "lastSeq": 4, "visitorUnreadCount": 3])
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient(unread: unread)
        _ = await client.sessionForChat(forceNew: false).value

        let initial = expectation(description: "current count on add")
        let three = expectation(description: "new count")
        let token = unread.add { count in
            XCTAssertTrue(Thread.isMainThread)
            if count == 0 { initial.fulfill() }
            if count == 3 { three.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 2)
        await client.refresh().value
        await fulfillment(of: [three], timeout: 2)

        XCTAssertEqual(unread.count, 3)
        XCTAssertEqual(StubURLProtocol.requests(to: "/conversations/current").first?.authorization, "Bearer t")
        unread.remove(token)
    }

    func testNoConversationMeansNothingUnread() async {
        let unread = UnreadCenter()
        unread.update(5)
        StubURLProtocol.install { request in
            switch request.path {
            case Path.sessions: return .json(201, Fixtures.session(token: "t", visitorId: "v", visitorKey: Fixtures.visitorKey))
            case Path.current: return .raw(200, "null")
            default: return .status(404)
            }
        }
        let client = Fixtures.makeClient(unread: unread)
        _ = await client.sessionForChat(forceNew: false).value
        await client.refresh().value
        XCTAssertEqual(unread.count, 0)
    }

    func testRefreshWithoutAVisitorCreatesNoSession() async {
        StubURLProtocol.install { _ in .status(500) }
        let unread = UnreadCenter()
        await Fixtures.makeClient(unread: unread).refresh().value
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(unread.count, 0)
    }

    func testRemovedListenersAreNotCalled() async {
        let unread = UnreadCenter()
        let removed = expectation(description: "removed listener")
        removed.isInverted = true
        let token = unread.add { count in
            if count == 7 { removed.fulfill() }
        }
        unread.remove(token)
        unread.update(7)
        await fulfillment(of: [removed], timeout: 0.5)
    }
}
