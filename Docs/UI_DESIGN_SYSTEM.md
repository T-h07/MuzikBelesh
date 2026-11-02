# UI design system

Phase 1 uses a locked dark SwiftUI appearance. `AppColors`, `AppSpacing`, and `AppRadius` in `OFFLINE/DesignSystem/DesignSystem.swift` are the shared tokens.

- Backgrounds: black, `#111111`, and `#222222`.
- Text: `#F5F5F5`, `#A0A0A0`, and `#777777`.
- Accent: restrained lime `#D6EEA3`.
- Feedback: green success, amber warning, and coral error.
- Typography: SwiftUI system fonts/SF Pro with Dynamic Type.
- Spacing: 4, 8, 12, 16, 20, 24, and 28 point tokens.
- Radii: 8, 12, 16, and 18 points; capsules for chips.
- Artwork: square, deterministic fixture artwork with consistent rounded corners.

Reusable components include `ArtworkView`, `TrackRow`, `AlbumCard`, `PlaylistCard`, `MiniPlayer`, `SearchBar`, `ProgressRow`, `EmptyState`, `ErrorState`, `FilterChip`, and `SectionHeader`. Controls use SF Symbols, native buttons, context menus, accessibility labels, and identifiers. The app remains dark even when the device uses light appearance.

