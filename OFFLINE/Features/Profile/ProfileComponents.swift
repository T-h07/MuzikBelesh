import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// Circular avatar: a managed image, or the default avatar when there is none.
struct AvatarCircle: View {
    let image: UIImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Circle().fill(AppColors.backgroundTertiary)
                    .overlay(Image(systemName: "person.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(AppColors.accentPrimary))
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().stroke(AppColors.divider, lineWidth: 1))
    }
}

private final class AvatarImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()
}

/// The stored profile's avatar. A missing or unreadable file falls back to the default avatar.
struct ProfileAvatarView: View {
    @EnvironmentObject private var profile: LocalProfileService
    let size: CGFloat
    var body: some View {
        // Each saved avatar has a new file name, so a changed avatar is a new task identity.
        AvatarFileView(url: profile.avatarURL(thumbnail: size <= 64), size: size)
    }
}

private struct AvatarFileView: View {
    let url: URL?
    let size: CGFloat
    @State private var image: UIImage?
    var body: some View {
        AvatarCircle(image: image, size: size)
            .task(id: url) {
                guard let url else { image = nil; return }
                let pixels = Int(size * 3)
                let key = "\(url.lastPathComponent)|\(pixels)" as NSString
                if let cached = AvatarImageCache.shared.object(forKey: key) { image = cached; return }
                let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary)
                    else { return nil }
                    return UIImage(cgImage: cgImage)
                }.value
                if let loaded { AvatarImageCache.shared.setObject(loaded, forKey: key) }
                if !Task.isCancelled { image = loaded }
            }
    }
}

/// Home header control that opens the Profile page.
struct ProfileHeaderButton: View {
    @EnvironmentObject private var profile: LocalProfileService
    let action: () -> Void
    var body: some View {
        Button(action: action) { ProfileAvatarView(size: 34).frame(width: 44, height: 44) }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile")
            .accessibilityValue(profile.profile?.username ?? "")
            .accessibilityIdentifier("home-profile-button")
    }
}

/// Username input with live validation feedback and a character count.
struct UsernameField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// Show "Enter a username" only once the person has interacted with the field.
    let showsEmptyError: Bool
    let onSubmit: () -> Void

    private var violation: UsernamePolicy.Violation? {
        if case .failure(let violation) = UsernamePolicy.validate(text) { return violation }
        return nil
    }
    private var visibleViolation: UsernamePolicy.Violation? {
        guard let violation else { return nil }
        return violation == .empty && !showsEmptyError ? nil : violation
    }
    private var count: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Username").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
            TextField("", text: $text, prompt: Text("Your name").foregroundStyle(AppColors.textTertiary))
                .focused(focus)
                .textContentType(.nickname)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .foregroundStyle(AppColors.textPrimary)
                .padding(.horizontal, AppSpacing.md).frame(minHeight: 48)
                .background(AppColors.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).stroke(visibleViolation == nil ? AppColors.divider : AppColors.error, lineWidth: 1))
                .accessibilityLabel("Username")
                .accessibilityIdentifier("profile-username-field")
            HStack(alignment: .firstTextBaseline) {
                if let visibleViolation {
                    Text(visibleViolation.message).foregroundStyle(AppColors.error).accessibilityIdentifier("profile-username-error")
                } else {
                    Text("Shown only on this iPhone.").foregroundStyle(AppColors.textTertiary)
                }
                Spacer()
                Text("\(count)/\(UsernamePolicy.maximumLength)")
                    .foregroundStyle(count > UsernamePolicy.maximumLength ? AppColors.error : AppColors.textTertiary)
                    .accessibilityLabel("\(count) of \(UsernamePolicy.maximumLength) characters")
            }.font(.caption)
        }
    }
}

/// Photo selection through the system picker, which needs no photo-library permission.
/// The picked image is validated and downsampled in memory; nothing is written until Save.
struct ProfilePhotoControls: View {
    let hasPhoto: Bool
    let onPrepared: (PreparedAvatar) -> Void
    let onRemove: () -> Void
    let onError: (String) -> Void
    @Binding var isProcessing: Bool
    @State private var selection: PhotosPickerItem?

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            PhotosPicker(selection: $selection, matching: .images) {
                Label(hasPhoto ? "Change Photo" : "Add Photo", systemImage: "photo")
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.horizontal, AppSpacing.md)
                    .background(AppColors.backgroundSecondary).clipShape(Capsule())
            }
            .foregroundStyle(AppColors.accentPrimary)
            .disabled(isProcessing)
            .accessibilityIdentifier("profile-photo-picker")
            if hasPhoto {
                Button(role: .destructive, action: onRemove) {
                    Text("Remove").font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.horizontal, AppSpacing.md)
                }
                .foregroundStyle(AppColors.error)
                .disabled(isProcessing)
                .accessibilityLabel("Remove photo")
                .accessibilityIdentifier("profile-photo-remove")
            }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        isProcessing = true
        defer { isProcessing = false; selection = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw LocalProfileError.invalidImage }
            onPrepared(try await LocalProfileService.prepareAvatar(data))
        } catch {
            onError(((error as? LocalProfileError) ?? .invalidImage).errorDescription ?? "")
        }
    }
}

/// Decodes a prepared (already small) avatar for previews.
func previewImage(_ avatar: PreparedAvatar?) -> UIImage? { avatar.flatMap { UIImage(data: $0.full) } }

/// Large avatar plus a spinner while a picked photo is being prepared.
struct AvatarPreview: View {
    let image: UIImage?
    let storedFallback: Bool
    let size: CGFloat
    let processing: Bool
    var body: some View {
        ZStack {
            if let image { AvatarCircle(image: image, size: size) }
            else if storedFallback { ProfileAvatarView(size: size) }
            else { AvatarCircle(image: nil, size: size) }
            if processing { Circle().fill(.black.opacity(0.5)).frame(width: size, height: size); ProgressView().tint(AppColors.textPrimary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image != nil || storedFallback ? "Profile photo" : "Default profile picture")
        .accessibilityIdentifier("profile-avatar-preview")
    }
}
