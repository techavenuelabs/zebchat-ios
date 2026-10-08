import Foundation

/// The visitor session and everything that needs it (docs/MOBILE_SDK.md §5).
///
/// Every operation runs on `queue`, one at a time and in call order, so the session state below
/// is only ever touched by one operation. Public entry points return the operation's task.
final class ZebChatClient: @unchecked Sendable {
    /// Screen views kept while offline.
    static let screenBufferMax = 20

    let siteKey: String
    let options: ZebChatOptions
    let app: AppInfo

    private let api: APIClient
    private let state: SDKState
    private let unread: UnreadCenter
    private let now: @Sendable () -> Date
    private let queue = SerialTaskQueue()

    // Touched only inside queue operations.
    private var session: StoredSession?
    private var pendingScreens: [PendingScreen] = []

    // Readable from any thread.
    private let localeValue: Locked<String>
    private let chatOpen = Locked(false)
    /// Told (on the main actor) when the session changes while the chat is open.
    private let sessionHandler = Locked<(@MainActor @Sendable (StoredSession) -> Void)?>(nil)

    struct PendingScreen: Equatable, Sendable {
        let url: String
        let title: String
    }

    init(
        siteKey: String,
        options: ZebChatOptions,
        app: AppInfo,
        store: SecureStore,
        urlSession: URLSession = APIClient.makeSession(),
        unread: UnreadCenter = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.siteKey = siteKey
        self.options = options
        self.app = app
        self.api = APIClient(baseURL: options.apiBaseURL, app: app, session: urlSession)
        self.state = SDKState(store: store)
        self.unread = unread
        self.now = now
        self.localeValue = Locked(options.locale)
        self.session = state.session
    }

    // MARK: - Thread-safe flags

    var locale: String {
        get { localeValue.get() }
        set { localeValue.set(newValue) }
    }

    var isChatOpen: Bool { chatOpen.get() }

    /// Called by the chat screen (main actor) when it appears or goes away.
    func setChatOpen(_ open: Bool, onSessionChange: (@MainActor @Sendable (StoredSession) -> Void)?) {
        chatOpen.set(open)
        sessionHandler.set(open ? onSessionChange : nil)
    }

    /// The chat page URL for the next `show()`.
    func chatPageURL() -> URL? {
        MobileBridge.pageURL(
            base: options.chatPageURL,
            siteKey: siteKey,
            appId: app.appId,
            sdk: app.sdk,
            locale: locale
        )
    }

    // MARK: - Operations

    /// The session for an `init` (re-created when `forceNew`, e.g. after the page reported `expired`).
    @discardableResult
    func sessionForChat(forceNew: Bool) -> Task<Result<StoredSession, APIError>, Never> {
        queue.enqueue { [self] in
            do {
                let chatSession = try await ensureSession(forceNew: forceNew)
                return .success(chatSession)
            } catch {
                Log.error("Could not start the chat session: \(describe(error))")
                return .failure(error as? APIError ?? .invalidResponse)
            }
        }
    }

    /// The page renewed its own token (same visitor).
    @discardableResult
    func tokenRenewed(token: String, expiresAt: String) -> Task<Void, Never> {
        queue.enqueue { [self] in
            guard var current = session else { return }
            current.token = token
            current.expiresAt = expiresAt
            store(current)
        }
    }

    @discardableResult
    func setUser(_ user: ZebChatUser) -> Task<Void, Never> {
        queue.enqueue { [self] in
            await applyUser(user)
        }
    }

    @discardableResult
    func logout() -> Task<Void, Never> {
        queue.enqueue { [self] in
            await performLogout()
            await reinitializeOpenChat()
        }
    }

    @discardableResult
    func trackScreen(_ name: String) -> Task<Void, Never> {
        queue.enqueue { [self] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let screen = String(trimmed.prefix(AppScreen.nameMax))
            pendingScreens.append(PendingScreen(
                url: AppScreen.url(appId: app.appId, screen: screen),
                title: String(screen.prefix(AppScreen.titleMax))
            ))
            if pendingScreens.count > Self.screenBufferMax {
                pendingScreens.removeFirst(pendingScreens.count - Self.screenBufferMax)
            }
            await flushScreens()
        }
    }

    @discardableResult
    func track(event name: String, properties: [String: String]?) -> Task<Void, Never> {
        queue.enqueue { [self] in
            do {
                try await authorized { token in
                    try await api.event(token: token, name: name, properties: properties)
                }
            } catch {
                Log.error("Event not recorded: \(describe(error))")
            }
        }
    }

    @discardableResult
    func setPushToken(_ token: String) -> Task<Void, Never> {
        queue.enqueue { [self] in
            if let previous = state.registeredDevice, previous.token != token, hasVisitor {
                // A rotated FCM token: drop the old registration (a rejected token gets one retry
                // with a new session, as on logout).
                do {
                    try await authorized { visitorToken in
                        try await api.deleteDevice(token: visitorToken, pushToken: previous.token)
                    }
                } catch {
                    // Registering the new token for the same visitor supersedes it anyway.
                    Log.error("Old push token not deleted: \(describe(error))")
                }
                state.registeredDevice = nil
            }
            state.pushToken = token
            do {
                let current = try await ensureSession()
                await syncDevice(current)
            } catch {
                Log.error("Push token not registered yet: \(describe(error))")
            }
        }
    }

    /// Refreshes the unread count (app foreground, ZebChat push, chat closed) and sends buffered screens.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        queue.enqueue { [self] in
            if !pendingScreens.isEmpty {
                await flushScreens()
            }
            // No visitor yet: nothing can be unread, and no session is created just to find out.
            guard hasVisitor else {
                unread.update(0)
                return
            }
            do {
                let count = try await authorized { token in try await api.unreadCount(token: token) }
                unread.update(count)
            } catch {
                Log.error("Unread count not refreshed: \(describe(error))")
            }
        }
    }

    /// Test hook: the current state, read in queue order.
    func snapshot() -> Task<(session: StoredSession?, pendingScreens: [PendingScreen]), Never> {
        queue.enqueue { [self] in (session: session, pendingScreens: pendingScreens) }
    }

    // MARK: - Session

    private var hasVisitor: Bool {
        session != nil || state.visitorKey != nil || state.user != nil
    }

    /// Cached session, or `POST /widget/sessions` (+ `POST /widget/identify` with a user).
    private func ensureSession(forceNew: Bool = false) async throws -> StoredSession {
        let user = state.user
        if !forceNew, let current = session, current.user == user, current.isFresh(at: now()) {
            return current
        }
        var response = try await api.createSession(siteKey: siteKey, visitorKey: state.visitorKey)
        if let visitorKey = response.visitorKey {
            state.visitorKey = visitorKey
        }
        if let user {
            response = try await identify(response, as: user)
        }
        return await adopt(response, user: user)
    }

    /// Identifies `anonymous` as `user`. A refused identity (bad hash, verification off) keeps the
    /// anonymous visitor, as on the web; transport errors are thrown.
    private func identify(_ anonymous: WidgetSessionResponse, as user: ZebChatUser) async throws -> WidgetSessionResponse {
        do {
            return try await api.identify(token: anonymous.visitorToken, user: user)
        } catch APIError.http(let status) where status == 400 || status == 403 {
            Log.error("setUser was refused (HTTP \(status)); the chat continues as an anonymous visitor.")
            return anonymous
        }
    }

    /// Caches the session and re-registers the push token when the visitor changed.
    private func adopt(_ response: WidgetSessionResponse, user: ZebChatUser?) async -> StoredSession {
        let adopted = StoredSession(
            token: response.visitorToken,
            expiresAt: response.visitorTokenExpiresAt,
            visitor: response.visitor,
            user: user
        )
        store(adopted)
        await syncDevice(adopted)
        return adopted
    }

    private func store(_ newSession: StoredSession?) {
        session = newSession
        state.session = newSession
    }

    /// `POST /widget/devices` unless this token is already registered for this visitor.
    private func syncDevice(_ current: StoredSession) async {
        guard let pushToken = state.pushToken else { return }
        if state.registeredDevice == RegisteredDevice(token: pushToken, visitorId: current.visitor.id) { return }
        do {
            try await api.registerDevice(token: current.token, pushToken: pushToken)
            state.registeredDevice = RegisteredDevice(token: pushToken, visitorId: current.visitor.id)
        } catch {
            Log.error("Push token not registered: \(describe(error))")
        }
    }

    /// Runs a visitor call; a rejected token (401) gets one retry with a new session.
    private func authorized<T>(_ call: (String) async throws -> T) async throws -> T {
        let current = try await ensureSession()
        do {
            return try await call(current.token)
        } catch APIError.http(status: 401) {
            let renewed = try await ensureSession(forceNew: true)
            return try await call(renewed.token)
        }
    }

    // MARK: - User

    private func applyUser(_ user: ZebChatUser) async {
        let previous = state.user
        guard previous != user else { return }
        if let previousId = previous?.id, previousId != user.id {
            // Another account signed in without logout(): never carry the old visitor over.
            await performLogout()
        }
        state.user = user
        if let current = session, current.isFresh(at: now()) {
            do {
                let response = try await identify(
                    WidgetSessionResponse(
                        visitorToken: current.token,
                        visitorTokenExpiresAt: current.expiresAt,
                        visitorKey: nil,
                        visitor: current.visitor
                    ),
                    as: user
                )
                _ = await adopt(response, user: user)
            } catch {
                // Expired token or offline: identify again with the next session.
                Log.error("setUser deferred: \(describe(error))")
                store(nil)
            }
        }
        await reinitializeOpenChat()
    }

    /// `logout()`: delete the push device **before** forgetting the visitor key and the user.
    private func performLogout() async {
        if let pushToken = state.pushToken, state.registeredDevice != nil {
            do {
                try await authorized { token in
                    try await api.deleteDevice(token: token, pushToken: pushToken)
                }
            } catch {
                // The next registration moves the token to the new visitor anyway.
                Log.error("Push device not deleted on logout: \(describe(error))")
            }
        }
        state.clearIdentity()
        session = nil
        pendingScreens.removeAll()
        unread.update(0)
    }

    /// `setUser` / `logout` while the chat is open → a new `init` for the page.
    private func reinitializeOpenChat() async {
        guard isChatOpen, let handler = sessionHandler.get() else { return }
        do {
            let current = try await ensureSession()
            await MainActor.run {
                handler(current)
            }
        } catch {
            Log.error("Could not restart the open chat: \(describe(error))")
        }
    }

    // MARK: - Screens

    private func flushScreens() async {
        while let next = pendingScreens.first {
            do {
                try await authorized { token in
                    try await api.pageview(token: token, url: next.url, title: next.title)
                }
                pendingScreens.removeFirst()
            } catch let error as APIError where error.isRetryable {
                return
            } catch {
                Log.error("Screen view dropped: \(describe(error))")
                pendingScreens.removeFirst()
            }
        }
    }

    private func describe(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return "unexpected error" }
        switch apiError {
        case .network: return "network unavailable"
        case .http(let status): return "HTTP \(status)"
        case .invalidResponse: return "invalid response"
        }
    }
}
