import AVFoundation
import Foundation

final class AudioRouteMonitor {
    private let session = AVAudioSession.sharedInstance()
    var onRouteChanged: ((String, AVAudioSession.RouteChangeReason) -> Void)?
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            let reason = AVAudioSession.RouteChangeReason(rawValue: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0) ?? .unknown
            self?.onRouteChanged?(self?.session.currentRoute.outputs.map(\.portName).joined(separator: ", ") ?? "No audio route", reason)
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
