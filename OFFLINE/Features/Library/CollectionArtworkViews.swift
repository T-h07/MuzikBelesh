import PhotosUI
import SwiftUI

/// Phase 11.5: the one artwork view for every multi-song collection surface (Library rows,
/// Home, Search, detail headers, settings). It asks `CollectionArtworkService` what to show,
/// so the same collection shows the same covers everywhere during an epoch, at any size.
struct CollectionArtworkView: View {
    @EnvironmentObject private var artwork: CollectionArtworkService
    let identity: CollectionArtworkIdentity
    let size: CGFloat
    var title: String = ""
    /// Rows already announce the collection name; their artwork is hidden from VoiceOver.
    var decorative = false

    init(identity: CollectionArtworkIdentity, size: CGFloat, title: String = "", decorative: Bool = false) {
        self.identity = identity; self.size = size; self.title = title; self.decorative = decorative
    }
    init(kind: CollectionArtworkKind, collectionID: String, size: CGFloat, title: String = "", decorative: Bool = false) {
        self.init(identity: CollectionArtworkIdentity(kind: kind, id: collectionID), size: size, title: title, decorative: decorative)
    }

    var body: some View {
        let presentation = artwork.presentation(for: identity)
        CollectionArtworkCanvas(presentation: presentation, size: size, fallbackID: identity.id)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(presentation, title: title))
            .accessibilityValue(Self.value(presentation))
            .accessibilityAddTraits(.isImage)
            .accessibilityHidden(decorative)
            .accessibilityIdentifier("collection-artwork-\(identity.kind.rawValue)-\(identity.id)")
    }

    static func label(_ presentation: CollectionArtworkPresentation, title: String) -> String {
        let name = title.isEmpty ? "this collection" : title
        switch presentation {
        case .custom: return "Custom artwork for \(name)"
        case .mosaic: return "Automatic artwork for \(name)"
        case .single, .placeholder: return "Artwork for \(name)"
        }
    }
    static func value(_ presentation: CollectionArtworkPresentation) -> String {
        switch presentation {
        case .custom: return "Custom cover"
        case .mosaic(let selection): return selection.coverCount == 1 ? "1 song cover" : "\(selection.coverCount) song covers"
        case .single: return "Song cover"
        case .placeholder: return "No song covers"
        }
    }
}

/// Draws one presentation and changes it atomically: the next composition is decoded first,
/// then fades in over the previous one (which stays fully opaque underneath), so nothing
/// flashes to black and quadrants never change one by one. Reduce Motion swaps instantly.
/// The frame never changes, so rows and headers keep their layout.
struct CollectionArtworkCanvas: View {
    @EnvironmentObject private var artwork: CollectionArtworkService
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let presentation: CollectionArtworkPresentation
    let size: CGFloat
    var fallbackID: String = "collection"

    /// Crossfade between complete compositions.
    static let transitionDuration: Double = 0.3
    /// Reduce Motion replaces artwork without animation.
    static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeInOut(duration: transitionDuration) }

    struct Composition {
        let key: String
        let presentation: CollectionArtworkPresentation
        let images: [UIImage?]
    }
    private struct LoadKey: Hashable {
        let presentation: String
        let bucket: Int
        let foreground: Bool
    }

    @State private var previous: Composition?
    @State private var current: Composition?
    @State private var currentOpacity: Double = 1
    @State private var isVisible = false
    @State private var fadeCleanup: Task<Void, Never>?

    private var isMosaic: Bool { if case .mosaic = presentation { return true }; return false }
    /// Each tile is half the artwork; never decode a full-size cover for a small quadrant.
    private var bucket: Int { ArtworkImagePipeline.bucket(points: isMosaic ? size / 2 : size, scale: displayScale) }
    private var compositionKey: String { "\(presentation.key)#\(bucket)" }

    var body: some View {
        ZStack {
            if current == nil { base }
            if let previous { layer(previous) }
            if let current { layer(current).opacity(currentOpacity) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            // Never leave a half-finished fade behind: settle on the current composition.
            fadeCleanup?.cancel(); fadeCleanup = nil
            previous = nil; currentOpacity = 1
        }
        .task(id: LoadKey(presentation: presentation.key, bucket: bucket, foreground: artwork.isForeground)) { await prepare() }
    }

    /// Before the first composition is ready: the neutral form of what is coming.
    @ViewBuilder private var base: some View {
        if isMosaic { mosaic(Array(repeating: nil, count: CollectionMosaicSelection.slotCount)) }
        else { ArtworkView(name: fallbackID, size: size) }
    }

    @ViewBuilder private func layer(_ composition: Composition) -> some View {
        switch composition.presentation {
        case .mosaic: mosaic(composition.images)
        case .custom, .single:
            if let image = composition.images.first ?? nil { Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipped() }
            else { ArtworkView(name: fallbackID, size: size) }
        case .placeholder: ArtworkView(name: fallbackID, size: size)
        }
    }

    /// Four equal square tiles, aspect-filled, with a hairline gutter. Only the outer frame is
    /// rounded (by the canvas clip); tiles have no corners of their own.
    private func mosaic(_ images: [UIImage?]) -> some View {
        let gutter: CGFloat = size >= 120 ? 1 : 0.5
        let tile = (size - gutter) / 2
        return VStack(spacing: gutter) {
            HStack(spacing: gutter) { cell(0, images, tile); cell(1, images, tile) }
            HStack(spacing: gutter) { cell(2, images, tile); cell(3, images, tile) }
        }
        .frame(width: size, height: size)
        .background(AppColors.backgroundPrimary)
    }

    @ViewBuilder private func cell(_ index: Int, _ images: [UIImage?], _ tile: CGFloat) -> some View {
        if images.indices.contains(index), let image = images[index] {
            Image(uiImage: image).resizable().scaledToFill().frame(width: tile, height: tile).clipped()
        } else { MosaicFallbackTile(side: tile) }
    }

    private func prepare() async {
        let target = presentation
        let key = compositionKey
        if current?.key == key { return }
        let slots = target.slots
        let pipeline = artwork.images
        // Fully cached (scrolling back, the same selection at the same size): draw at once.
        var images: [UIImage?] = slots.map { slot in slot.flatMap { pipeline.cached(path: $0, bucket: bucket) } }
        let complete = zip(slots, images).allSatisfy { slot, image in slot == nil || image != nil }
        if !complete {
            // No decoding in the background, and none without managed storage; the previous
            // composition (or the neutral base) stays until the app is active again.
            guard artwork.isForeground, let paths = artwork.paths else { return }
            let bucket = bucket
            let results = await withTaskGroup(of: (Int, ArtworkLoadResult).self) { group -> [Int: ArtworkLoadResult] in
                for (index, slot) in slots.enumerated() {
                    guard let slot, images[index] == nil else { continue }
                    group.addTask { (index, await pipeline.load(path: slot, bucket: bucket, paths: paths)) }
                }
                var collected: [Int: ArtworkLoadResult] = [:]
                for await (index, result) in group { collected[index] = result }
                return collected
            }
            guard !Task.isCancelled else { return }
            if results.values.contains(where: { if case .cancelled = $0 { return true }; return false }) { return }
            for (index, result) in results {
                images[index] = result.image
                if result.isUnusable, let path = slots[index] { artwork.reportUnusable(path) }
            }
        }
        show(Composition(key: key, presentation: target, images: images))
    }

    /// Only a real artwork change on screen crossfades: the first composition, a size or
    /// display-scale change of the same artwork, and anything off screen swap instantly, so no
    /// animation is ever left pending in a view that is not being drawn.
    static func shouldCrossfade(from current: CollectionArtworkPresentation?, to next: CollectionArtworkPresentation,
                                visible: Bool, reduceMotion: Bool) -> Bool {
        guard visible, !reduceMotion, let current else { return false }
        return current.key != next.key
    }

    private func show(_ next: Composition) {
        fadeCleanup?.cancel(); fadeCleanup = nil
        guard Self.shouldCrossfade(from: current?.presentation, to: next.presentation, visible: isVisible, reduceMotion: reduceMotion),
              let animation = Self.animation(reduceMotion: reduceMotion) else {
            previous = nil; current = next; currentOpacity = 1
            return
        }
        previous = current
        current = next
        currentOpacity = 0
        withAnimation(animation) { currentOpacity = 1 }
        // The fully covered previous layer is dropped after the fade, without an animation
        // completion handler.
        fadeCleanup = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.transitionDuration + 0.05))
            guard !Task.isCancelled else { return }
            if current?.key == next.key { previous = nil }
        }
    }
}

/// A neutral quadrant for collections with fewer than four covers: dark, quiet, square.
struct MosaicFallbackTile: View {
    let side: CGFloat
    var body: some View {
        ZStack {
            Rectangle().fill(AppColors.backgroundSecondary)
            Image(systemName: "music.note").font(.system(size: max(6, side * 0.3), weight: .medium))
                .foregroundStyle(AppColors.textTertiary.opacity(0.55))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - Settings

/// Settings → Appearance: the global switch.
struct AutomaticCollectionArtworkSetting: View {
    @EnvironmentObject private var artwork: CollectionArtworkService
    @Environment(\.themePalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ListeningStyle.eyebrow("Collections")
            Toggle(isOn: Binding(get: { artwork.automaticByDefault }, set: { artwork.setAutomaticByDefault($0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatic Collection Artwork").font(.headline).foregroundStyle(AppColors.textPrimary)
                    Text("Automatically create rotating covers from songs in your collections.")
                        .font(.subheadline).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(palette.controlTint)
            .frame(minHeight: 44)
            .accessibilityIdentifier("appearance-automatic-artwork")
            Text("Show rotating song-cover mosaics for playlists, albums, and collections without custom artwork. Custom covers always take priority, and each collection can choose its own setting.")
                .font(.caption).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
            if let error = artwork.lastError {
                Text(error).font(.caption).foregroundStyle(AppColors.warning).accessibilityIdentifier("appearance-artwork-error")
            }
        }
        .padding(AppSpacing.lg)
        .background(AppColors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

/// Playlist/album menu → Artwork Settings.
struct CollectionArtworkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @EnvironmentObject private var artwork: CollectionArtworkService
    @EnvironmentObject private var library: MusicLibraryService
    let identity: CollectionArtworkIdentity
    let title: String
    @State private var selection: PhotosPickerItem?
    @State private var working = false
    @State private var confirmingRemoval = false
    @State private var error: String?

    private var hasCustomCover: Bool { artwork.hasCustomCover(identity) }
    private var mode: CollectionArtworkMode { artwork.mode(for: identity) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: AppSpacing.md) {
                        CollectionArtworkView(identity: identity, size: 180, title: title)
                        Text(status).font(.subheadline).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("collection-artwork-status")
                    }.frame(maxWidth: .infinity).padding(.vertical, AppSpacing.sm)
                }.listRowBackground(AppColors.backgroundSecondary)

                Section {
                    ForEach(CollectionArtworkMode.allCases) { option in
                        Button { artwork.setMode(option, for: identity) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(AppColors.textPrimary)
                                    Text(detail(option)).font(.caption).foregroundStyle(AppColors.textSecondary)
                                }
                                Spacer()
                                if mode == option { Image(systemName: "checkmark").foregroundStyle(palette.accent).accessibilityHidden(true) }
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(mode == option ? .isSelected : [])
                        .accessibilityIdentifier("collection-artwork-mode-\(option.rawValue)")
                    }
                    if hasCustomCover && artwork.mosaicEnabled(for: identity) {
                        Text("Your custom cover takes priority. Remove it to display the automatic mosaic.")
                            .font(.caption).foregroundStyle(AppColors.textSecondary).accessibilityIdentifier("collection-artwork-custom-note")
                    }
                    if let message = artwork.lastError { Text(message).font(.caption).foregroundStyle(AppColors.warning) }
                } header: { Text("Automatic Artwork") }
                    .listRowBackground(AppColors.backgroundSecondary)

                Section {
                    if let preview = artwork.mosaicPreview(for: identity) {
                        HStack {
                            CollectionArtworkCanvas(presentation: .mosaic(preview), size: 120, fallbackID: identity.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Automatic mosaic preview")
                                .accessibilityValue(CollectionArtworkView.value(.mosaic(preview)))
                                .accessibilityAddTraits(.isImage)
                                .accessibilityIdentifier("collection-artwork-preview")
                            Spacer()
                        }
                    } else {
                        Text("Add songs with artwork to create a mosaic.").font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                    Button { artwork.refresh(identity) } label: { Label("Refresh Mosaic", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!artwork.canRefresh(identity))
                        .accessibilityIdentifier("collection-artwork-refresh")
                    Text("Mosaics change by themselves every 30 minutes. Refreshing never changes the songs, their order or their metadata.")
                        .font(.caption).foregroundStyle(AppColors.textTertiary)
                } header: { Text("Mosaic Preview") }
                    .listRowBackground(AppColors.backgroundSecondary)

                if identity.kind.supportsCustomCover {
                    Section {
                        PhotosPicker(selection: $selection, matching: .images) {
                            Label(hasCustomCover ? "Change Cover" : "Choose Custom Cover", systemImage: "photo")
                        }
                        .disabled(working)
                        .accessibilityIdentifier("collection-artwork-change-cover")
                        if hasCustomCover {
                            Button(role: .destructive) { confirmingRemoval = true } label: { Label("Remove Custom Cover", systemImage: "trash") }
                                .disabled(working)
                                .accessibilityIdentifier("collection-artwork-remove-cover")
                        }
                        if let error { Text(error).font(.caption).foregroundStyle(AppColors.error) }
                    } header: { Text("Custom Cover") }
                        .listRowBackground(AppColors.backgroundSecondary)
                }
            }
            .scrollContentBackground(.hidden).screenBackground()
            .navigationTitle("Artwork Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("collection-artwork-done") } }
            .confirmationDialog("Remove Custom Cover?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove Cover", role: .destructive) { change(nil) }.accessibilityIdentifier("collection-artwork-confirm-remove")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(artwork.mosaicEnabled(for: identity) ? "The automatic mosaic will be shown instead. Your songs and their artwork are kept." : "A song cover will be shown instead. Your songs and their artwork are kept.")
            }
            .task(id: selection) {
                guard let selection else { return }
                do {
                    guard let value = try await selection.loadTransferable(type: Data.self) else { throw LibraryError.invalidImage }
                    let processed = try await Task.detached { try ManagedLibraryFiles.imageData(value, pixels: 1024) }.value
                    guard !Task.isCancelled else { return }
                    change(processed)
                } catch is CancellationError { } catch { self.error = MusicLibraryService.message(error) }
                self.selection = nil
            }
        }
    }

    private var status: String {
        switch artwork.presentation(for: identity) {
        case .custom: return "Showing your custom cover."
        case .mosaic(let selection): return "Showing an automatic mosaic of \(selection.coverCount == 1 ? "1 song cover" : "\(selection.coverCount) song covers")."
        case .single: return "Showing a single song cover."
        case .placeholder: return "No song artwork yet."
        }
    }

    private func detail(_ option: CollectionArtworkMode) -> String {
        switch option {
        case .appDefault: return "Follows Settings → Appearance (currently \(artwork.automaticByDefault ? "on" : "off"))."
        case .automatic: return "Show a mosaic of this collection's song covers."
        case .staticArtwork: return "Show one song cover; no mosaic."
        }
    }

    private func change(_ data: Data?) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do { try await library.setCollectionCover(identity, artworkData: data); error = nil }
            catch { self.error = MusicLibraryService.message(error) }
        }
    }
}
