import SwiftUI
import UIKit

/// Read-only bridge for the native keyboard region. TabView's tab controller does
/// not resize its tab bar with SwiftUI keyboard avoidance, so the root uses this
/// window-coordinate boundary to size the complete tab area, including its bar.
struct KeyboardLayoutRegion: UIViewRepresentable {
    let changed: (CGFloat?) -> Void
    func makeUIView(context: Context) -> KeyboardRegionView {
        let view = KeyboardRegionView()
        view.changed = changed
        return view
    }
    func updateUIView(_ view: KeyboardRegionView, context: Context) {
        view.changed = changed
        view.setNeedsLayout()
    }
}

final class KeyboardRegionView: UIView {
    var changed: ((CGFloat?) -> Void)?
    private var lastTop: CGFloat?
    private var reported = false
    override init(frame: CGRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        keyboardLayoutGuide.usesBottomSafeArea = false
        let region = UIView()
        region.translatesAutoresizingMaskIntoConstraints = false
        region.isUserInteractionEnabled = false
        addSubview(region)
        NSLayoutConstraint.activate([
            region.leadingAnchor.constraint(equalTo: leadingAnchor),
            region.trailingAnchor.constraint(equalTo: trailingAnchor),
            region.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            region.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, bounds.height > 0 else { return }
        let region = keyboardLayoutGuide.layoutFrame
        let top: CGFloat? = region.height > 0.5 && bounds.maxY - region.minY > 0.5 ? convert(region, to: window).minY : nil
        if reported {
            if top == nil && lastTop == nil { return }
            if let top, let lastTop, abs(top - lastTop) < 0.5 { return }
        }
        lastTop = top; reported = true
        // Defer publication until UIKit has finished the current layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.changed?(top)
        }
    }
}
