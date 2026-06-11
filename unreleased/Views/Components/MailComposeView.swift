import MessageUI
import SwiftUI

/// A SwiftUI wrapper around `MFMailComposeViewController`.
/// Present this as a sheet; it calls `onDismiss` when the user is done.
struct MailComposeView: UIViewControllerRepresentable {
    let toRecipients: [String]
    let subject: String
    var body: String = ""
    var onDismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(toRecipients)
        vc.setSubject(subject)
        if !body.isEmpty { vc.setMessageBody(body, isHTML: false) }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposeView

        init(_ parent: MailComposeView) {
            self.parent = parent
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true)
            parent.onDismiss?()
        }
    }
}
