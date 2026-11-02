# Remote controls and Now Playing

`RemoteCommandCoordinator` registers play, pause, toggle, next, previous, and change-position handlers on `MPRemoteCommandCenter`. Every handler targets the same `AudioPlayerService` instance created by `AppContainer`.

`NowPlayingInfoCoordinator` publishes title, resolved artist/album names, artwork, duration, elapsed time, and playback rate through `MPNowPlayingInfoCenter`. Lock Screen, Control Center, AirPods, and supported Bluetooth/headset controls therefore use the same service and state as the SwiftUI player.
