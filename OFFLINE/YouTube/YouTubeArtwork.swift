import SwiftUI
import ImageIO

actor YouTubeArtworkLoader {
    private let transport: any YouTubeTransport
    private var cache: [URL: (UIImage, Date)] = [:]
    init(transport: any YouTubeTransport = YouTubeURLSessionTransport()) { self.transport = transport }
    func downloadData(for url: URL?) async -> Data? {
        guard let url, let image = try? await image(for: url) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }
    func image(for url: URL) async throws -> UIImage? {
        guard YouTubeImageURL.valid(url) != nil else { return nil }
        cache = cache.filter { Date().timeIntervalSince($0.value.1) < 180 }
        if let hit = cache[url] { return hit.0 }
        let response = try await transport.send(URLRequest(url: url))
        try Task.checkCancellation()
        guard response.status == 200, response.data.count <= 3_000_000,
              let source = CGImageSourceCreateWithData(response.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        if cache.count >= 30, let oldest = cache.min(by: { $0.value.1 < $1.value.1 })?.key { cache.removeValue(forKey: oldest) }
        cache[url] = (image, Date())
        return image
    }
}

struct YouTubeArtwork: View {
    @EnvironmentObject private var container: AppContainer
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Rectangle().fill(AppColors.backgroundSecondary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "play.rectangle").foregroundStyle(AppColors.textTertiary) }
        }.clipped().accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = try? await container.youtubeArtwork.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
