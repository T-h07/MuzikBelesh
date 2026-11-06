import Foundation

struct ProgressCadence {
    let interval: TimeInterval
    private var previous: TimeInterval?
    init(seconds: TimeInterval) { interval = seconds }
    mutating func due(at now: TimeInterval) -> Bool {
        if let previous, now - previous < interval { return false }
        previous = now
        return true
    }
}

struct TransferRate {
    private var previous: (TimeInterval, Int64)?
    private(set) var bytesPerSecond: Double?
    mutating func record(bytes: Int64, at now: TimeInterval) -> Bool {
        if let (time, count) = previous {
            let elapsed = now - time
            guard elapsed >= 0.45, bytes >= count else { return false }
            let rate = Double(bytes - count) / elapsed
            bytesPerSecond = (bytesPerSecond ?? rate) * 0.6 + rate * 0.4
        }
        previous = (now, bytes)
        return true
    }
}
