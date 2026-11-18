import SwiftUI
import ImageIO
import UIKit
import UIKit

/// Fixed colours: backgrounds, text, dividers and status. The user-selectable accent lives in
/// `ThemePalette` (read with `@Environment(\.themePalette)`), never here.
enum AppColors {
    static let backgroundPrimary = Color.black
    static let backgroundSecondary = Color(hex: "111111")
    static let backgroundTertiary = Color(hex: "222222")
    static let textPrimary = Color(hex: "F5F5F5")
    static let textSecondary = Color(hex: "A0A0A0")
    static let textTertiary = Color(hex: "777777")
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
    @Environment(\.themePalette) private var palette
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View { HStack { Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(AppColors.textPrimary); Spacer(); if let actionTitle, let action { Button(actionTitle, action: action).font(.caption).foregroundStyle(palette.accent) } } }
}

struct ArtworkView: View {
    let name: String
    var size: CGFloat
    var body: some View { ZStack { RoundedRectangle(cornerRadius: AppRadius.medium).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)); Image(systemName: "music.note").font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.white.opacity(0.88)) }.frame(width: size, height: size) }
    private var colors: [Color] { let options: [[Color]] = [[Color(hex: "24302A"), Color(hex: "101510")], [Color(hex: "2A3024"), Color(hex: "11150D")], [Color(hex: "303326"), Color(hex: "111111")]]; let stable = name.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }; return options[abs(stable) % options.count] }
}

struct StoredArtworkView: View {
    let track: StoredTrack
    let size: CGFloat
    var body: some View { ManagedArtworkView(path: track.artworkRelativePath, fallbackID: track.id, size: size) }
}

/// One song (or other single) cover from managed storage. Decoding and caching go through the
/// shared `ArtworkImagePipeline`, the same bounded cache used by collection mosaics.
struct ManagedArtworkView: View {
    @EnvironmentObject private var library: MusicLibraryService
    @Environment(\.displayScale) private var displayScale
    let path: String?
    let fallbackID: String
    let size: CGFloat
    @State private var image: UIImage?
    private var bucket: Int { ArtworkImagePipeline.bucket(points: size, scale: displayScale) }
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { ArtworkView(name: fallbackID, size: size) }
        }.frame(width: size, height: size).clipped().clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
            .task(id: "\(path ?? "none")|\(bucket)") {
                guard let path, let storage = library.storage else { image = nil; return }
                let pipeline = ArtworkImagePipeline.shared
                // A cached image is shown at once; a new path never keeps the previous image.
                if let cached = pipeline.cached(path: path, bucket: bucket) { image = cached; return }
                image = nil
                let loaded = await pipeline.load(path: path, bucket: bucket, paths: storage.paths).image
                if !Task.isCancelled { image = loaded }
            }
    }
}

struct EmptyState: View {
    @Environment(\.themePalette) private var palette
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View { VStack(spacing: AppSpacing.md) { Image(systemName: icon).font(.system(size: 34)).foregroundStyle(palette.accent); Text(title).font(.headline).foregroundStyle(AppColors.textPrimary); Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(AppColors.textSecondary); if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(.black) } }.frame(maxWidth: .infinity).padding(.vertical, 48) }
}

struct FilterChip: View {
    @Environment(\.themePalette) private var palette
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View { Button(action: action) { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(selected ? palette.onAccent : AppColors.textSecondary).padding(.horizontal, 14).padding(.vertical, 8).background(selected ? palette.accent : AppColors.backgroundSecondary).clipShape(Capsule()) }.accessibilityAddTraits(selected ? .isSelected : []) }
}
