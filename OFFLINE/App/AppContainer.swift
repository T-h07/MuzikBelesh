import Foundation
struct AppContainer {
    let configuration: AppConfiguration
    let youtubeProbe: YouTubeProbe
    init(configuration: AppConfiguration = .current(), youtubeProbe: YouTubeProbe = YouTubeKitProbe()) { self.configuration = configuration; self.youtubeProbe = youtubeProbe }
}

