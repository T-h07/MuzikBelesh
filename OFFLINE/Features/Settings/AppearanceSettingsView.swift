import SwiftUI

/// Phase 11.3 Appearance: presets, a native custom colour and reset. Opened from Profile and from
/// Settings; both entry points use the one `ThemeService` from the environment.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var theme: ThemeService
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var swatchColumn: CGFloat = 78

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                AppearancePreview()
                presets
                custom
                reset
                AutomaticCollectionArtworkSetting()
                Text("Your accent colour changes highlights, buttons, sliders and charts. Muzik Belesh keeps its black background, and colours for errors and warnings never change.")
                    .font(.caption).foregroundStyle(AppColors.textTertiary)
                    .accessibilityIdentifier("appearance-note")
            }
            .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.lg)
        }
        .screenBackground()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: theme.selection)
        .onDisappear { theme.commitCustomColor() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Appearance").font(.system(size: 30, weight: .bold)).foregroundStyle(AppColors.textPrimary).accessibilityAddTraits(.isHeader)
            Text("Make Muzik Belesh yours.").font(.subheadline).foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ListeningStyle.eyebrow("Colours")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: swatchColumn), spacing: AppSpacing.md)], spacing: AppSpacing.lg) {
                ForEach(ThemePreset.allCases) { preset in
                    swatchButton(color: preset.rgb, name: preset.name, selected: theme.selection == .preset(preset), identifier: "appearance-preset-\(preset.rawValue)") {
                        apply { theme.select(preset) }
                    }
                }
            }
        }
    }

    private func swatchButton(color: ThemeRGB, name: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.sm) {
                AppearanceSwatch(color: color, selected: selected, size: 48)
                Text(name).font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AppColors.textPrimary : AppColors.textSecondary)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(ListeningPressStyle())
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: Custom

    private var custom: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ListeningStyle.eyebrow("Custom")
            HStack(spacing: AppSpacing.lg) {
                Button { apply { theme.selectCustom() } } label: {
                    AppearanceSwatch(color: theme.customColor, selected: theme.selection == .custom, size: 64)
                        .frame(minWidth: 72, minHeight: 72).contentShape(Rectangle())
                }
                .buttonStyle(ListeningPressStyle())
                .accessibilityLabel("Custom colour \(theme.customColor.hex)")
                .accessibilityValue(theme.selection == .custom ? "Selected" : "")
                .accessibilityAddTraits(theme.selection == .custom ? .isSelected : [])
                .accessibilityIdentifier("appearance-custom-swatch")
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.selection == .custom ? "Custom colour in use" : "Your custom colour")
                        .font(.headline).foregroundStyle(AppColors.textPrimary)
                    Text(theme.customColor.hex).font(.subheadline.monospaced()).foregroundStyle(AppColors.textSecondary)
                        .accessibilityIdentifier("appearance-custom-hex")
                    if theme.selection == .custom && palette.isAdjustedForContrast {
                        Text("Shown lighter on controls so it stays readable on black.")
                            .font(.caption).foregroundStyle(AppColors.textTertiary)
                            .accessibilityIdentifier("appearance-contrast-note")
                    }
                }
                Spacer(minLength: 0)
            }
            ColorPicker(selection: customBinding, supportsOpacity: false) {
                Label("Choose a Custom Colour", systemImage: "eyedropper").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("appearance-custom-picker")
            if let error = theme.lastError {
                Text(error).font(.caption).foregroundStyle(AppColors.warning).accessibilityIdentifier("appearance-error")
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }

    /// Live: every change from the system picker applies at once; writes are coalesced.
    private var customBinding: Binding<Color> {
        Binding(get: { theme.customColor.color },
                set: { color in if let rgb = ThemeRGB(color: color) { theme.updateCustomColor(rgb) } })
    }

    private var reset: some View {
        Button { apply { theme.reset() } } label: {
            Label("Restore Original Theme", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(AppColors.textPrimary)
                .background(AppColors.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.medium).stroke(AppColors.divider))
        }
        .buttonStyle(ListeningPressStyle())
        .disabled(theme.selection == .default)
        .opacity(theme.selection == .default ? 0.5 : 1)
        .accessibilityIdentifier("appearance-reset")
    }

    /// Preset and reset changes cross-fade briefly; Reduce Motion applies them at once.
    private func apply(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.22)) { change() } }
    }
}

/// A colour swatch. Selection is shown by a ring and a checkmark, never by colour alone; very
/// dark colours get a light outline so they stay visible on black.
struct AppearanceSwatch: View {
    let color: ThemeRGB
    let selected: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = ThemePalette(chosen: color)
        ZStack {
            Circle().fill(color.color)
            if color.contrast(with: .black) < 3 { Circle().stroke(AppColors.textTertiary, lineWidth: 1) }
            if selected {
                Image(systemName: "checkmark").font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(color.contrast(with: .black) >= color.contrast(with: .white) ? Color.black : Color.white)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .padding(5)
        .overlay(Circle().stroke(selected ? palette.accent : .clear, lineWidth: 2.5))
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .accessibilityHidden(true)
    }
}

/// A non-interactive sample of the interface drawn with the live palette.
struct AppearancePreview: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack {
                ListeningStyle.eyebrow("Preview")
                Spacer()
                Text("Not playable").font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
            HStack(spacing: AppSpacing.md) {
                RoundedRectangle(cornerRadius: AppRadius.small).fill(AppColors.backgroundTertiary).frame(width: 48, height: 48)
                    .overlay(Image(systemName: "music.note").foregroundStyle(palette.accent))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now Playing").font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(AppColors.backgroundTertiary)
                            Capsule().fill(palette.accent).frame(width: proxy.size.width * 0.42)
                        }
                    }.frame(height: 4)
                }
                Circle().fill(palette.accent).frame(width: 40, height: 40)
                    .overlay(Image(systemName: "play.fill").foregroundStyle(palette.onAccent))
            }
            HStack(spacing: AppSpacing.sm) {
                Text("Primary").font(.subheadline.weight(.semibold)).foregroundStyle(palette.onAccent)
                    .padding(.horizontal, AppSpacing.lg).frame(minHeight: 34).background(Capsule().fill(palette.accent))
                Text("Filter").font(.subheadline).foregroundStyle(palette.accent)
                    .padding(.horizontal, AppSpacing.lg).frame(minHeight: 34).overlay(Capsule().stroke(palette.accentBorder))
                Spacer()
                Image(systemName: "heart.fill").foregroundStyle(palette.accent)
                Image(systemName: "shuffle").foregroundStyle(palette.accent)
            }
            Divider().overlay(AppColors.divider)
            HStack {
                tab("house.fill", "Home", selected: true)
                tab("magnifyingglass", "Search", selected: false)
                tab("music.note.list", "Library", selected: false)
                tab("arrow.down.circle", "Downloads", selected: false)
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the interface with the current accent colour")
        .accessibilityIdentifier("appearance-preview")
    }

    private func tab(_ icon: String, _ title: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
            Text(title).font(.caption2)
        }
        .foregroundStyle(selected ? palette.accent : AppColors.textTertiary)
        .frame(maxWidth: .infinity)
    }
}
