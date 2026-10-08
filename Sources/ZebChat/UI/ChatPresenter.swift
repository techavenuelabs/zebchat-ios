import UIKit

/// Presents one chat screen at a time.
@MainActor
final class ChatPresenter {
    static let shared = ChatPresenter()

    private weak var controller: ZebChatViewController?

    func show(client: ZebChatClient, from presenter: UIViewController) {
        if let controller, controller.presentingViewController != nil, !controller.isBeingDismissed {
            return
        }
        guard let pageURL = client.chatPageURL() else {
            Log.error("ZebChat.show: the chat page URL is invalid.")
            return
        }
        let chat = ZebChatViewController(client: client, pageURL: pageURL)
        controller = chat
        topmost(from: presenter).present(chat, animated: true)
    }

    /// Presenting from a controller that already presents something would fail; climb to the top.
    private func topmost(from presenter: UIViewController) -> UIViewController {
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }
}
