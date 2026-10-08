import UIKit
import ZebChat

/// Every SDK call in one screen. (An example app: its labels are not localized.)
final class DemoViewController: UIViewController {
    private let chatButton = UIButton(type: .system)
    private var unreadToken: ZebChatListenerToken?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ZebChat"
        view.backgroundColor = .systemBackground

        chatButton.setTitle("Open chat", for: .normal)
        chatButton.addTarget(self, action: #selector(openChat), for: .touchUpInside)

        let signInButton = button("Sign in as demo user", #selector(signIn))
        let signOutButton = button("Log out", #selector(signOut))
        let screenButton = button("Track screen “Checkout”", #selector(trackCheckout))
        let frenchButton = button("Chat in French next time", #selector(useFrench))

        let stack = UIStackView(arrangedSubviews: [chatButton, signInButton, signOutButton, screenButton, frenchButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        unreadToken = ZebChat.addUnreadListener { [weak self] count in
            self?.chatButton.setTitle(count > 0 ? "Open chat (\(count) unread)" : "Open chat", for: .normal)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ZebChat.trackScreen("Home")
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func openChat() {
        ZebChat.show(from: self)
    }

    @objc private func signIn() {
        // In a real app the hash comes from your server: HMAC-SHA256(user id, identity secret).
        // Without a hash only name and email are sent, as unverified details.
        ZebChat.setUser(ZebChatUser(email: "demo@example.com", name: "Demo User"))
    }

    @objc private func signOut() {
        ZebChat.logout()
    }

    @objc private func trackCheckout() {
        ZebChat.trackScreen("Checkout")
    }

    @objc private func useFrench() {
        ZebChat.setLocale("fr")
    }
}
