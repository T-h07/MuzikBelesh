import SwiftUI

enum AppColors {
    static let backgroundPrimary = Color.black
    static let backgroundSecondary = Color(hex: "111111")
    static let backgroundTertiary = Color(hex: "222222")
    static let textPrimary = Color(hex: "F5F5F5")
    static let textSecondary = Color(hex: "A0A0A0")
    static let textTertiary = Color(hex: "777777")
    static let accentPrimary = Color(hex: "D6EEA3")
    static let divider = Color(hex: "292929")
    static let success = Color(hex: "78C49A")
    static let warning = Color(hex: "E9BF76")
    static let error = Color(hex: "E88C86")
}

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let section: CGFloat = 28
}

enum AppRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let card: CGFloat = 16
    static let large: CGFloat = 18
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255, opacity: 1)
    }
}

struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View { content.background(AppColors.backgroundPrimary.ignoresSafeArea()) }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
    func cardSurface() -> some View { padding(AppSpacing.lg).background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.card)) }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View { HStack { Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(AppColors.textPrimary); Spacer(); if let actionTitle, let action { Button(actionTitle, action: action).font(.caption).foregroundStyle(AppColors.accentPrimary) } } }
}

struct ArtworkView: View {
    let name: String
    var size: CGFloat
    var body: some View { ZStack { RoundedRectangle(cornerRadius: AppRadius.medium).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)); Image(systemName: "music.note").font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.white.opacity(0.88)) }.frame(width: size, height: size) }
    private var colors: [Color] { let options: [[Color]] = [[.indigo, .purple], [.orange, .red], [.blue, .cyan], [.green, .teal], [.pink, .purple]]; return options[abs(name.hashValue) % options.count] }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View { VStack(spacing: AppSpacing.md) { Image(systemName: icon).font(.system(size: 34)).foregroundStyle(AppColors.accentPrimary); Text(title).font(.headline).foregroundStyle(AppColors.textPrimary); Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(AppColors.textSecondary); if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).tint(AppColors.accentPrimary).foregroundStyle(.black) } }.frame(maxWidth: .infinity).padding(.vertical, 48) }
}

struct ErrorState: View {
    let title: String
    let message: String
    var retry: (() -> Void)?
    var body: some View { VStack(spacing: AppSpacing.md) { Image(systemName: "exclamationmark.triangle").foregroundStyle(AppColors.error); Text(title).font(.headline).foregroundStyle(AppColors.textPrimary); Text(message).font(.subheadline).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center); if let retry { Button("Try Again", action: retry).foregroundStyle(AppColors.accentPrimary) } }.frame(maxWidth: .infinity).padding(.vertical, 40) }
}

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View { Button(action: action) { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(selected ? .black : AppColors.textSecondary).padding(.horizontal, 14).padding(.vertical, 8).background(selected ? AppColors.accentPrimary : AppColors.backgroundSecondary).clipShape(Capsule()) }.accessibilityAddTraits(selected ? .isSelected : []) }
}

