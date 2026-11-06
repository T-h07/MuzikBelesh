import Foundation
import Combine

struct ResourcePolicy: Equatable {
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPower = false
    var defersNewWork: Bool { thermal == .serious || thermal == .critical }
    var conservesResources: Bool { lowPower || thermal != .nominal }
    var allowsMaintenance: Bool { !conservesResources }
    func downloadLimit(_ requested: Int) -> Int {
        if defersNewWork { return 0 }
        return conservesResources ? min(1, requested) : requested
    }
    func playbackInterval(foreground: Bool) -> TimeInterval {
        foreground ? (conservesResources ? 1 : 0.5) : 5
    }
    var thermalLabel: String {
        switch thermal {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

@MainActor final class ResourceMonitor: ObservableObject {
    @Published private(set) var policy: ResourcePolicy
    private var observers: [NSObjectProtocol] = []
    init(observeSystem: Bool = true) {
        policy = observeSystem ? Self.current() : ResourcePolicy()
        guard observeSystem else { return }
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    let current = Self.current()
                    if self?.policy != current { self?.policy = current }
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private static func current() -> ResourcePolicy {
        ResourcePolicy(thermal: ProcessInfo.processInfo.thermalState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
