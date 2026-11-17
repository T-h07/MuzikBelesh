import SwiftUI

/// The Profile page, opened from the Home header avatar.
struct LocalProfileView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profile: LocalProfileService
    @State private var editing: ProfileEditFocus?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    if let current = profile.profile {
                        header(current)
                        section("Account") {
                            row("Edit Username", icon: "person.text.rectangle", identifier: "profile-edit-username") { editing = .username }
                            Divider().overlay(AppColors.divider)
                            row("Change Profile Picture", icon: "photo.on.rectangle", identifier: "profile-change-photo") { editing = .photo }
                        }
                    } else { unavailable }
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("LISTENING ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary).accessibilityAddTraits(.isHeader)
                        ListeningPreviewCard()
                    }
                    section("Personalization") {
                        NavigationLink { AppearanceSettingsView() } label: {
                            HStack(spacing: AppSpacing.md) {
                                Image(systemName: "paintpalette").foregroundStyle(palette.accent).frame(width: 24)
                                Text("Appearance").foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                Circle().fill(palette.accent).frame(width: 14, height: 14).accessibilityHidden(true)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                            }.frame(minHeight: 52).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("profile-appearance")
                    }
                    section("Coming Later") {
                        planned("Music Sharing", icon: "square.and.arrow.up.on.square", detail: "Library export and import")
                    }
                    section("Settings") {
                        row("Settings", icon: "gearshape", identifier: "profile-open-settings") { showingSettings = true }
                    }
                    Text("Your profile is a local display name and photo for personalization. It isn't a sign-in, has no password and is never uploaded.")
                        .font(.caption).foregroundStyle(AppColors.textTertiary)
                }
                .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.lg)
            }
            .screenBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("profile-done") } }
            .sheet(item: $editing) { focus in
                if let current = profile.profile { EditProfileView(original: current, focus: focus) }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }

    private func header(_ current: LocalUserProfile) -> some View {
        VStack(spacing: AppSpacing.md) {
            ProfileAvatarView(size: 120)
                .accessibilityLabel(current.hasCustomAvatar ? "Profile photo" : "Default profile picture")
                .accessibilityIdentifier("profile-avatar")
            Text(current.username).font(.system(size: 26, weight: .bold)).foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center).accessibilityIdentifier("profile-username")
            Button { editing = .username } label: {
                Text("Edit Profile").font(.subheadline.weight(.semibold)).foregroundStyle(palette.onAccent)
                    .padding(.horizontal, AppSpacing.xl).frame(minHeight: 40)
                    .background(palette.accent).clipShape(Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("profile-edit")
        }.frame(maxWidth: .infinity).padding(.top, AppSpacing.md)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Profile unavailable").font(.headline).foregroundStyle(AppColors.textPrimary)
            if case .failed(let message) = profile.state { Text(message).font(.subheadline).foregroundStyle(AppColors.textSecondary) }
            Button("Try Again") { profile.load() }.foregroundStyle(palette.accent).frame(minHeight: 44)
                .accessibilityIdentifier("profile-retry")
        }.frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, AppSpacing.lg)
                .background(AppColors.backgroundSecondary).clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    private func row(_ title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon).foregroundStyle(palette.accent).frame(width: 24)
                Text(title).foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
            }.frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }

    /// A clearly labelled, non-interactive preview of a later feature. Not a button.
    private func planned(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon).foregroundStyle(AppColors.textTertiary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(AppColors.textSecondary)
                Text(detail).font(.caption).foregroundStyle(AppColors.textTertiary)
            }
            Spacer()
            Text("Planned").font(.caption2.weight(.semibold)).foregroundStyle(AppColors.textTertiary)
                .padding(.horizontal, AppSpacing.sm).padding(.vertical, 3).overlay(Capsule().stroke(AppColors.divider))
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not available yet")
    }
}

enum ProfileEditFocus: String, Identifiable { case username, photo; var id: String { rawValue } }

/// Draft editing: nothing is written until Save, Cancel discards, and a failed save keeps
/// the editor open with the stored profile unchanged.
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profile: LocalProfileService
    let original: LocalUserProfile
    let focus: ProfileEditFocus
    @State private var username: String
    @State private var avatar: AvatarChange = .keep
    @State private var preview: UIImage?
    @State private var processingPhoto = false
    @State private var errorMessage: String?
    @FocusState private var usernameFocused: Bool

    init(original: LocalUserProfile, focus: ProfileEditFocus) {
        self.original = original
        self.focus = focus
        _username = State(initialValue: original.username)
    }

    private var normalized: String? { if case .success(let value) = UsernamePolicy.validate(username) { return value }; return nil }
    private var showsPhoto: Bool {
        switch avatar { case .keep: return original.hasCustomAvatar; case .remove: return false; case .replace: return true }
    }
    /// An invalid draft (nil) counts as a change so it can't be dismissed silently.
    private var hasChanges: Bool { normalized != original.username || avatar != .keep }
    private var canSave: Bool { normalized != nil && hasChanges && !profile.isSaving && !processingPhoto }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xxl) {
                    VStack(spacing: AppSpacing.lg) {
                        AvatarPreview(image: preview, storedFallback: avatar == .keep, size: 120, processing: processingPhoto)
                        ProfilePhotoControls(hasPhoto: showsPhoto,
                                             onPrepared: { avatar = .replace($0); preview = previewImage($0) },
                                             onRemove: { avatar = original.hasCustomAvatar ? .remove : .keep; preview = nil },
                                             onError: { errorMessage = $0 },
                                             isProcessing: $processingPhoto)
                    }
                    UsernameField(text: $username, focus: $usernameFocused, showsEmptyError: true, onSubmit: save)
                }
                .padding(.horizontal, AppSpacing.xxl).padding(.vertical, AppSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(profile.isSaving).accessibilityIdentifier("edit-profile-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if profile.isSaving { ProgressView() }
                    else { Button("Save", action: save).fontWeight(.semibold).disabled(!canSave).accessibilityIdentifier("edit-profile-save") }
                }
            }
            .interactiveDismissDisabled(hasChanges || profile.isSaving)
            .onAppear { if focus == .username { usernameFocused = true } }
            .alert("Profile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard canSave else { return }
        usernameFocused = false
        let name = username, change = avatar
        Task {
            do {
                try await profile.saveChanges(username: name, avatar: change)
                dismiss()
            } catch { errorMessage = ((error as? LocalProfileError) ?? .saveFailed).errorDescription }
        }
    }
}
