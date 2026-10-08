import UIKit
import WebKit

/// The full-screen chat: `mobile.html` in a WKWebView, handed the native session over bridge v1
/// (docs/MOBILE_SDK.md §2, §5).
@MainActor
final class ZebChatViewController: UIViewController {
    let client: ZebChatClient
    private let pageURL: URL
    private var webView: WKWebView?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let closeButton = UIButton(type: .system)
    private var errorView: UIView?
    /// How long a loaded page may take to say `ready` before the native error screen shows.
    static let readyTimeoutNanoseconds: UInt64 = 15_000_000_000
    /// The page said `ready`; `init` messages can be delivered.
    private var pageReady = false
    /// The page reported an error; the native close button stays until the next `ready` + `init`.
    private var pageFailed = false
    private var readyTimeout: Task<Void, Never>?
    private var downloads: [ObjectIdentifier: URL] = [:]

    init(client: ZebChatClient, pageURL: URL) {
        self.client = client
        self.pageURL = pageURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func text(_ key: String) -> String {
        L10n.string(key, locale: client.locale)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let webView = makeWebView()
        self.webView = webView
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.accessibilityLabel = text(L10n.loading)
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // A native way out while the page is loading or failed (the page has its own close button).
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .label
        closeButton.accessibilityLabel = text(L10n.close)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        loadPage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        client.setChatOpen(true) { [weak self] session in
            self?.deliver(session)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let dismissed = isBeingDismissed || presentingViewController == nil
            || presentingViewController?.isBeingDismissed == true
        guard dismissed else { return }
        cancelReadyTimeout()
        client.setChatOpen(false, onSessionChange: nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: MobileBridge.messageHandlerName
        )
        // Unread count after the chat closes.
        client.refresh()
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            ScriptMessageProxy(target: self),
            name: MobileBridge.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        // Safe areas come from the page's CSS (viewport-fit=cover, env(safe-area-inset-*)).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    private func loadPage() {
        hideError()
        cancelReadyTimeout()
        pageReady = false
        pageFailed = false
        closeButton.isHidden = false
        spinner.startAnimating()
        webView?.load(URLRequest(url: pageURL))
    }

    /// The page loaded but has not said `ready`: give it a moment, then offer Retry / Close.
    private func startReadyTimeout() {
        cancelReadyTimeout()
        readyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ZebChatViewController.readyTimeoutNanoseconds)
            guard !Task.isCancelled, let self, !self.pageReady else { return }
            Log.error("The chat page did not report ready in time.")
            self.showError()
        }
    }

    private func cancelReadyTimeout() {
        readyTimeout?.cancel()
        readyTimeout = nil
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func retryTapped() {
        loadPage()
    }

    // MARK: - Bridge

    func receive(_ message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard MobileBridge.isTrustedSender(
            isMainFrame: frame.isMainFrame,
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port,
            pageURL: pageURL
        ) else {
            Log.error("Ignored a bridge message from an untrusted frame.")
            return
        }
        guard let parsed = MobilePageMessage.parse(message.body) else { return }
        switch parsed {
        case .ready:
            // The native close button stays until an `init` has been handed over.
            pageReady = true
            pageFailed = false
            cancelReadyTimeout()
            hideError()
            spinner.stopAnimating()
            startSession(forceNew: false)
        case let .renewed(token, expiresAt):
            client.tokenRenewed(token: token, expiresAt: expiresAt)
        case .expired:
            startSession(forceNew: true)
        case .close:
            dismiss(animated: true)
        case let .error(status, detail):
            Log.error("Chat page error \(status)", detail: detail)
            // Whatever the page shows now, the user always has a way out.
            pageFailed = true
            closeButton.isHidden = false
        }
    }

    private func startSession(forceNew: Bool) {
        let task = client.sessionForChat(forceNew: forceNew)
        Task { [weak self] in
            let result = await task.value
            guard let self else { return }
            switch result {
            case let .success(session):
                self.deliver(session)
            case .failure:
                self.showError()
            }
        }
    }

    /// Sends `init` with this session (a new token re-mounts the page's chat).
    func deliver(_ session: StoredSession) {
        guard pageReady, let webView, let script = MobileBridge.initScript(for: session) else { return }
        webView.evaluateJavaScript(script) { [weak self] _, error in
            let delivered = error == nil
            Task { @MainActor in
                self?.initDelivered(delivered)
            }
        }
    }

    /// After a successful `init` the page's own close button takes over from the native one.
    private func initDelivered(_ delivered: Bool) {
        guard delivered else {
            Log.error("Could not hand the session to the chat page.")
            closeButton.isHidden = false
            return
        }
        if pageReady, !pageFailed, errorView == nil {
            closeButton.isHidden = true
        }
    }

    // MARK: - Error state

    private func showError() {
        cancelReadyTimeout()
        spinner.stopAnimating()
        closeButton.isHidden = false
        guard errorView == nil else { return }

        let title = UILabel()
        title.text = text(L10n.errorTitle)
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.numberOfLines = 0

        let message = UILabel()
        message.text = text(L10n.errorMessage)
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        let retry = UIButton(type: .system)
        retry.setTitle(text(L10n.retry), for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, message, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let overlay = UIView()
        overlay.backgroundColor = .systemBackground
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        view.insertSubview(overlay, belowSubview: closeButton)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
        errorView = overlay
    }

    private func hideError() {
        errorView?.removeFromSuperview()
        errorView = nil
    }

    private func loadFailed(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads and loads we stopped by policy are not failures.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        Log.error("The chat page did not load (\(nsError.domain) \(nsError.code)).")
        showError()
    }

    // MARK: - Links and files

    private func route(_ url: URL, policy: LinkPolicy) {
        switch policy {
        case .download:
            startFileDownload(url)
        case .openExternally:
            openExternally(url)
        case .allow, .block:
            break
        }
    }

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), LinkPolicy.externalSchemes.contains(scheme) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func startFileDownload(_ url: URL) {
        if #available(iOS 14.5, *), let webView {
            webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
                download.delegate = self
            }
        } else {
            openExternally(url)
        }
    }

    private func share(_ file: URL) {
        guard presentedViewController == nil else {
            DownloadFiles.discard(file)
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        // The temporary copy is only for the share sheet.
        sheet.completionWithItemsHandler = { _, _, _, _ in
            DownloadFiles.discard(file)
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension ZebChatViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        guard let frame = navigationAction.targetFrame else {
            // target=_blank: let WebKit ask `createWebViewWith`, which routes it natively (no window).
            decisionHandler(.allow)
            return
        }
        var policy = LinkPolicy.decide(
            url: url,
            target: frame.isMainFrame ? .mainFrame : .subframe,
            pageURL: pageURL,
            apiBaseURL: client.options.apiBaseURL
        )
        // Only a tap leaves the app; scripted or redirected main-frame navigations are dropped.
        if policy == .openExternally, navigationAction.navigationType != .linkActivated {
            policy = .block
        }
        decisionHandler(policy == .allow ? .allow : .cancel)
        route(url, policy: policy)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode >= 400 {
            decisionHandler(.cancel)
            showError()
            return
        }
        guard navigationResponse.canShowMIMEType else {
            if #available(iOS 14.5, *) {
                decisionHandler(.download)
            } else {
                decisionHandler(.cancel)
                if let url = navigationResponse.response.url { openExternally(url) }
            }
            return
        }
        decisionHandler(.allow)
    }

    @available(iOS 14.5, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    @available(iOS 14.5, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !pageReady else { return }
        spinner.stopAnimating()
        if errorView == nil { startReadyTimeout() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// The web content process was killed (memory pressure): reload; the page says `ready` again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPage()
    }
}

// MARK: - WKUIDelegate

extension ZebChatViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            let policy = LinkPolicy.decide(
                url: url,
                target: .newWindow,
                pageURL: pageURL,
                apiBaseURL: client.options.apiBaseURL
            )
            route(url, policy: policy)
        }
        return nil
    }
}

// MARK: - WKDownloadDelegate

@available(iOS 14.5, *)
extension ZebChatViewController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let destination = DownloadFiles.destination(for: suggestedFilename) else {
            completionHandler(nil)
            return
        }
        downloads[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            DownloadFiles.discard(file)
        }
        Log.error("An attachment download failed.")
    }
}

// MARK: - Script message proxy

/// WKUserContentController retains its handlers; this proxy keeps the controller from leaking.
@MainActor
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: ZebChatViewController?

    init(target: ZebChatViewController) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
