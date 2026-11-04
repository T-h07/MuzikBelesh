import SwiftUI
import UIKit

/// UIKit owns the tab controller's physical bounds. Constrain its hosting view
/// above the native keyboard guide instead of relying on TabView's size proposal.
struct KeyboardSafeHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    func makeUIViewController(context: Context) -> KeyboardSafeHostingController<Content> {
        KeyboardSafeHostingController(content: content)
    }
    func updateUIViewController(_ controller: KeyboardSafeHostingController<Content>, context: Context) {
        controller.hosting.rootView = content
    }
}

final class KeyboardSafeHostingController<Content: View>: UIViewController {
    let hosting: UIHostingController<Content>
    init(content: Content) {
        hosting = UIHostingController(rootView: content)
        // UIKit's guide already excludes the keyboard. SwiftUI's default .all
        // applies a second keyboard inset to the same hierarchy while animating.
        hosting.safeAreaRegions = .container
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .black
        view.addSubview(hosting.view)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        hosting.didMove(toParent: self)
    }
    override var childForStatusBarStyle: UIViewController? { hosting }
    override var childForStatusBarHidden: UIViewController? { hosting }
}
