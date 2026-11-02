import Social
import UniformTypeIdentifiers
final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool { true }
    override func didSelectPost() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem, let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else { finish(); return }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let url: URL? = item as? URL ?? (item as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            DispatchQueue.main.async { self?.contentText = url.flatMap(SharedURLHandler.youtubeURL) == nil ? "No supported YouTube URL received." : "YouTube URL received. Copy-link fallback is available."; self?.finish() }
        }
    }
    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}

