import AVFoundation
import Foundation

final class AudioSessionManager {
    private let session = AVAudioSession.sharedInstance()
    private(set) var isActive = false

    func configure() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        isActive = false
    }

    var outputRouteName: String { session.currentRoute.outputs.map(\.portName).joined(separator: ", ").isEmpty ? "No audio route" : session.currentRoute.outputs.map(\.portName).joined(separator: ", ") }
}
