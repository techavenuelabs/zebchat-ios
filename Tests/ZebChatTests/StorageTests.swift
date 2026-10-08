import XCTest
@testable import ZebChat

final class StorageTests: XCTestCase {
    func testStateRoundTripsThroughTheStore() {
        let store = MemoryStore()
        let state = SDKState(store: store)
        let session = StoredSession(
            token: "tok",
            expiresAt: "2026-10-08T12:00:00.000Z",
            visitor: Fixtures.visitor("vis_1"),
            user: ZebChatUser(id: "42", hash: "abc")
        )
        state.visitorKey = Fixtures.visitorKey
        state.session = session
        state.user = ZebChatUser(id: "42", email: "a@b.com", name: "Ana", hash: "abc")
        state.pushToken = "fcm-1"
        state.registeredDevice = RegisteredDevice(token: "fcm-1", visitorId: "vis_1")

        // A new instance over the same store (an app restart) reads everything back.
        let reloaded = SDKState(store: store)
        XCTAssertEqual(reloaded.visitorKey, Fixtures.visitorKey)
        XCTAssertEqual(reloaded.session, session)
        XCTAssertEqual(reloaded.user, ZebChatUser(id: "42", email: "a@b.com", name: "Ana", hash: "abc"))
        XCTAssertEqual(reloaded.pushToken, "fcm-1")
        XCTAssertEqual(reloaded.registeredDevice, RegisteredDevice(token: "fcm-1", visitorId: "vis_1"))
    }

    func testClearIdentityKeepsOnlyThePushToken() {
        let store = MemoryStore()
        let state = SDKState(store: store)
        state.visitorKey = Fixtures.visitorKey
        state.session = StoredSession(token: "t", expiresAt: "2026-10-08T12:00:00Z", visitor: Fixtures.visitor("v"), user: nil)
        state.user = ZebChatUser(email: "a@b.com")
        state.pushToken = "fcm-1"
        state.registeredDevice = RegisteredDevice(token: "fcm-1", visitorId: "v")

        state.clearIdentity()

        XCTAssertNil(state.visitorKey)
        XCTAssertNil(state.session)
        XCTAssertNil(state.user)
        XCTAssertNil(state.registeredDevice)
        XCTAssertEqual(state.pushToken, "fcm-1")
    }

    func testCorruptEntriesReadAsMissing() {
        let store = MemoryStore()
        store.set(Data("{not json".utf8), forKey: SDKState.Key.session)
        XCTAssertNil(SDKState(store: store).session)
    }

    func testSessionsAreReusedUntilShortlyBeforeExpiry() {
        let now = Date()
        func session(expiringIn seconds: TimeInterval) -> StoredSession {
            StoredSession(token: "t", expiresAt: Fixtures.iso(now.addingTimeInterval(seconds)), visitor: Fixtures.visitor("v"), user: nil)
        }
        XCTAssertTrue(session(expiringIn: 12 * 3600).isFresh(at: now))
        XCTAssertTrue(session(expiringIn: 10 * 60).isFresh(at: now))
        XCTAssertFalse(session(expiringIn: 4 * 60).isFresh(at: now))
        XCTAssertFalse(session(expiringIn: -60).isFresh(at: now))
        XCTAssertFalse(StoredSession(token: "t", expiresAt: "soon", visitor: Fixtures.visitor("v"), user: nil).isFresh(at: now))
    }

    func testVisitorDecodesTheApiShape() throws {
        let json = #"{"id":"vis_1","name":null,"email":"a@b.com","phone":null,"verified":true}"#
        let visitor = try JSONDecoder().decode(ZebChatVisitor.self, from: Data(json.utf8))
        XCTAssertEqual(visitor, ZebChatVisitor(id: "vis_1", name: nil, email: "a@b.com", phone: nil, verified: true))
    }

    func testIdentifyBodyOmitsUnsetFields() throws {
        let data = try JSONEncoder().encode(ZebChatUser(id: "42", hash: "abc"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "hash"])
    }
}
