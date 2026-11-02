import Social
import UniformTypeIdentifiers
import UIKit
final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool { true }
    override func didSelectPost() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem, let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else { finish(); return }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let url: URL? = item as? URL ?? (item as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            DispatchQueue.main.async {
                let supported = url.flatMap(SharedURLHandler.youtubeURL) != nil
                let alert = UIAlertController(title: supported ? "OFFLINE" : "Unsupported URL", message: supported ? "YouTube URL received. Copy-link fallback is available." : "No supported YouTube URL received.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.finish() })
                self?.present(alert, animated: true)
            }
        }
    }
    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}

