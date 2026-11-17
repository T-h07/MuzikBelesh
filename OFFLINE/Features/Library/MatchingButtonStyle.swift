import SwiftUI
import UIKit

/// Outlined matching controls: transparent interior, thin border, 44-pt minimum target.
/// `.primary` is lime text with a lime border; `.secondary` is neutral and never
/// competes with the primary action.
struct MatchingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let tint = kind == .primary ? AppColors.accentPrimary : AppColors.textSecondary
        configuration.label
            .font(.subheadline.weight(kind == .primary ? .semibold : .regular))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background(configuration.isPressed ? tint.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(kind == .primary ? tint.opacity(0.9) : AppColors.textTertiary.opacity(0.7), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == MatchingButtonStyle {
    static var matchingPrimary: MatchingButtonStyle { MatchingButtonStyle(kind: .primary) }
    static var matchingPrimaryWide: MatchingButtonStyle { MatchingButtonStyle(kind: .primary, fullWidth: true) }
    static var matchingSecondary: MatchingButtonStyle { MatchingButtonStyle(kind: .secondary) }
    static var matchingSecondaryWide: MatchingButtonStyle { MatchingButtonStyle(kind: .secondary, fullWidth: true) }
}

enum KeyboardDismissal {
    /// Resigns any first responder (used before review navigation).
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
