import SwiftUI

/// First launch (or first launch after upgrading from v1.1.0): create the local profile.
/// The existing library is not read or written here; the tab interface opens once SQLite has
/// committed the profile.
struct LocalProfileOnboardingView: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var profile: LocalProfileService
    @State private var username = ""
    @State private var avatar: PreparedAvatar?
    @State private var preview: UIImage?
    @State private var processingPhoto = false
    @State private var interacted = false
    @State private var errorMessage: String?
    @FocusState private var usernameFocused: Bool

    private var isValid: Bool { if case .success = UsernamePolicy.validate(username) { return true }; return false }
    private var canSubmit: Bool { isValid && !profile.isSaving && !processingPhoto }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.xxl) {
                VStack(spacing: AppSpacing.sm) {
                    Text("Welcome to Muzik Belesh")
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding-title")
                    Text("Create a personal profile. It's stored only on this iPhone. No account, email or password needed.")
                        .font(.subheadline).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
                }
                VStack(spacing: AppSpacing.lg) {
                    AvatarPreview(image: preview, storedFallback: false, size: 132, processing: processingPhoto)
                    ProfilePhotoControls(hasPhoto: avatar != nil,
                                         onPrepared: { avatar = $0; preview = previewImage($0) },
                                         onRemove: { avatar = nil; preview = nil },
                                         onError: { errorMessage = $0 },
                                         isProcessing: $processingPhoto)
                    Text("A photo is optional.").font(.caption).foregroundStyle(AppColors.textTertiary)
                }
                UsernameField(text: $username, focus: $usernameFocused, showsEmptyError: interacted, onSubmit: submit)
                    .onChange(of: username) { _, _ in interacted = true }
                Button(action: submit) {
                    HStack(spacing: AppSpacing.sm) {
                        if profile.isSaving { ProgressView().tint(palette.onAccent) }
                        Text(profile.isSaving ? "Creating Profile…" : "Create Profile").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(palette.onAccent)
                    .background(canSubmit || profile.isSaving ? palette.accent : palette.accent.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityIdentifier("onboarding-create-profile")
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.top, 56).padding(.bottom, AppSpacing.xxl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .alert("Profile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func submit() {
        interacted = true
        guard canSubmit else { return }
        usernameFocused = false
        let name = username, photo = avatar
        Task {
            do { try await profile.createProfile(username: name, avatar: photo) }
            catch { errorMessage = ((error as? LocalProfileError) ?? .saveFailed).errorDescription }
        }
    }
}

/// Shown when the profile can't be read. Nothing is created or overwritten from here.
struct ProfileStorageErrorView: View {
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var profile: LocalProfileService
    let message: String
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(AppColors.warning)
            Text("Profile Unavailable").font(.title2.weight(.bold)).foregroundStyle(AppColors.textPrimary).accessibilityAddTraits(.isHeader)
            Text(message).font(.subheadline).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
                .accessibilityIdentifier("profile-error-message")
            Button { profile.load() } label: {
                Text("Try Again").font(.headline).frame(maxWidth: .infinity, minHeight: 52).foregroundStyle(palette.onAccent)
                    .background(palette.accent).clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
            }.buttonStyle(.plain).accessibilityIdentifier("profile-error-retry")
            Button("Continue to Library") { profile.continueWithoutProfile() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent).frame(minHeight: 44)
                .accessibilityIdentifier("profile-error-continue")
        }
        .padding(.horizontal, AppSpacing.xxl).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}
