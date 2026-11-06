# Navigation

The root `TabView` owns four independent native navigation stacks:

```text
RootView
├── Home NavigationStack
├── Search NavigationStack
├── Library NavigationStack
└── Downloads NavigationStack
    └── shared MiniPlayer
        └── full-screen Now Playing
```

`AppCoordinator` owns the selected tab, search query, library filter, sheet state, and Now Playing presentation. `AppContainer` injects the in-memory stores through the SwiftUI environment. The mini-player is rendered once above the tab bar and reads shared playback state. Settings, Import Link, and Sleep Timer use enum-backed sheet state; Now Playing uses one full-screen presentation.

Library details and Video Details use native `NavigationLink` destinations. Context menus provide mock play, queue, like, and playlist actions. No WebView, private API, or unsupported Share-to-app launch is used.

