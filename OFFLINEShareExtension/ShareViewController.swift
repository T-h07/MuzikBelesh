import UIKit

final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let primary = UIButton(type: .system)
    private let close = UIButton(type: .system)
    private var loading: Task<Void, Never>?
    private var videoID: String?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        let title = UILabel()
        title.text = "Muzik Belesh"
        title.font = .preferredFont(forTextStyle: .title2)
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.text = "Reading shared link…"
        primary.configuration = .filled()
        primary.tintColor = UIColor(red: 0.68, green: 0.95, blue: 0.18, alpha: 1)
        primary.configuration?.baseForegroundColor = .black
        primary.setTitle("Save Link", for: .normal)
        primary.isHidden = true
        primary.addTarget(self, action: #selector(save), for: .touchUpInside)
        close.setTitle("Cancel", for: .normal)
        close.addTarget(self, action: #selector(endRequest), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, message, primary, close])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
        ])
        let items = extensionContext?.inputItems ?? []
        loading = Task { [weak self] in
            do {
                let id = try await SharedURLHandler.extract(items)
                guard let self, !finished, !Task.isCancelled else { return }
                videoID = id
                message.text = "https://www.youtube.com/watch?v=\(id)"
                primary.isHidden = false
            } catch {
                guard let self, !finished, !Task.isCancelled else { return }
                message.text = (error as? ShareInputError)?.message ?? "Could not read the shared link."
                close.setTitle("Done", for: .normal)
            }
        }
    }

    @objc private func save() {
        guard let videoID, primary.isEnabled else { return }
        primary.isEnabled = false
        close.isEnabled = false
        isModalInPresentation = true
        message.text = "Saving link…"
        loading = Task { [weak self] in
            let result = await Task.detached { Result { try SharedLinkInbox.installed().save(videoID) } }.value
            guard let self, !finished, !Task.isCancelled else { return }
            isModalInPresentation = false
            close.isEnabled = true
            switch result {
            case .success:
                message.text = "Link saved. Open Muzik Belesh to inspect the video."
                primary.isHidden = true
                close.setTitle("Done", for: .normal)
            case .failure(let error):
                switch error as? SharedLinkInbox.Failure {
                case .unavailable: message.text = "Shared storage is unavailable. Check App Group access in both SideStore-signed targets."
                case .full: message.text = "The inbox is full. Open Muzik Belesh to review saved links."
                default: message.text = "Could not save the link. Try again."
                }
                primary.isEnabled = true
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loading?.cancel()
    }

    @objc private func endRequest() {
        guard !finished else { return }
        finished = true
        loading?.cancel()
        if close.title(for: .normal) == "Cancel" {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
