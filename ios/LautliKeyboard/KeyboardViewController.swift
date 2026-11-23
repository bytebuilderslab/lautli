import LautliKit
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(
        hasFullAccess: { [unowned self] in hasFullAccess },
        insertText: { [unowned self] in textDocumentProxy.insertText($0) },
        deleteBackward: { [unowned self] in textDocumentProxy.deleteBackward() },
        nextKeyboard: { [unowned self] in advanceToNextInputMode() },
        openContainingApp: { [unowned self] in openContainingApp($0) }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model, showsNextKeyboard: needsInputModeSwitchKey))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 230),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.refresh()
    }

    /// Keyboards have no public API to open their containing app. Like every dictation keyboard we surveyed
    /// (#33, Prior art), this walks the responder chain to UIApplication and calls its public `open` method,
    /// which is marked unavailable to extensions at compile time. App Review guideline 4.4.1 is the open risk.
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
