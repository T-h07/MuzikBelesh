import Foundation
import AVFoundation

enum DownloadFailure: String, Error {
    case rejected = "The media link expired or was rejected."
    case connection = "The connection was interrupted."
    case invalid = "The response did not contain a complete supported audio file."
    case disk = "The audio file could not be stored."
    case size = "The audio exceeds the download size limit."
}

protocol AudioTransferring: Sendable {
    func download(_ url: URL, to destination: URL, wifiOnly: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

enum DownloadMedia {
    static let limit: Int64 = 1_073_741_824
    static func permits(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased().hasSuffix(".googlevideo.com") == true else { return false }
        return YouTubeURLSessionTransport.permitted(url)
    }

    static func validate(_ file: URL) async throws {
        let asset = AVURLAsset(url: file)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard video.isEmpty, try await asset.load(.isPlayable),
              let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DownloadFailure.invalid }
        let formats = try await track.load(.formatDescriptions)
        guard formats.contains(where: {
            [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatAC3, kAudioFormatEnhancedAC3].contains(CMFormatDescriptionGetMediaSubType($0))
        }) else { throw DownloadFailure.invalid }
    }
}

struct TransferService: AudioTransferring {
    func download(_ url: URL, to destination: URL, wifiOnly: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard DownloadMedia.permits(url) else { throw DownloadFailure.rejected }
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = !wifiOnly
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 3600
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let delegate = MediaDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !wifiOnly
        let task = session.downloadTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation, task: task)
            }
        } onCancel: { delegate.cancel(task) }
    }
}

private final class MediaDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    // Only the serial session delegate queue accesses the transfer result.
    private var result: Result<Void, Error>?
    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }
    func start(_ continuation: CheckedContinuation<Void, Error>, task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        task.resume()
    }
    func cancel(_ task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(DownloadMedia.permits(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > DownloadMedia.limit {
            result = .failure(DownloadFailure.size)
            downloadTask.cancel()
        } else { progress(totalBytesWritten, totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard result == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, DownloadMedia.permits(response.url) else { throw DownloadFailure.invalid }
            if [401, 403, 410].contains(response.statusCode) { throw DownloadFailure.rejected }
            let length = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard response.statusCode == 200, ["audio/mp4", "audio/m4a", "audio/x-m4a", "application/octet-stream"].contains(response.mimeType ?? ""),
                  length > 0, length <= DownloadMedia.limit,
                  response.expectedContentLength < 0 || Int64(length) == response.expectedContentLength else { throw DownloadFailure.invalid }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch { result = .failure(error as? DownloadFailure ?? .disk) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let completion = continuation
        continuation = nil
        lock.unlock()
        completion?.resume(with: result ?? .failure(DownloadFailure.connection))
    }
}
