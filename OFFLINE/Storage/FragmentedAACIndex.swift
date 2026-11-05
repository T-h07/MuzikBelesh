import Foundation

/// Narrow reader for single-track, zero-based fragmented AAC files. Read only the
/// index and movie-fragment metadata. Skip every mdat without reading its payload.
enum FragmentedAACIndex {
    private struct Box {
        var type: String
        var body: Range<Int>
    }
    private static func uint32(_ data: Data, _ offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    private static func box(_ data: Data, at index: Int, limit: Int) -> Box? {
        guard limit - index >= 8 else { return nil }
        let size = uint32(data, index)
        guard size >= 8, size <= limit - index else { return nil }
        return Box(type: String(decoding: data[(index + 4)..<(index + 8)], as: UTF8.self), body: (index + 8)..<(index + size))
    }

    static func duration(of url: URL, sampleRate: Double) throws -> Double? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = Int(try file.seekToEnd())
        var offset = 0, referenced = 0, fragments = 0, packets = 0
        var indexDuration: Double?
        while offset < limit {
            try file.seek(toOffset: UInt64(offset))
            guard let header = try file.read(upToCount: 8), header.count == 8 else { return nil }
            let size = uint32(header, 0)
            guard size >= 8, size <= limit - offset else { return nil }
            let tag = String(decoding: header[4..<8], as: UTF8.self)
            if tag == "sidx" || tag == "moof" {
                guard size >= 12, size <= 2_000_000, let data = try file.read(upToCount: size - 8), data.count == size - 8 else { return nil }
                if tag == "sidx" {
                    guard indexDuration == nil, data[0] <= 1 else { return nil }
                    let version = data[0], start = version == 1 ? 32 : 24
                    guard data.count >= start, data[12..<(version == 1 ? 20 : 16)].allSatisfy({ $0 == 0 }) else { return nil }
                    referenced = Int(data[start - 2]) * 256 + Int(data[start - 1])
                    let scale = uint32(data, 8)
                    guard scale > 0, referenced > 0, data.count == start + 12 * referenced else { return nil }
                    var ticks = 0
                    for i in 0..<referenced {
                        let position = start + 12 * i
                        guard data[position] < 128 else { return nil }
                        ticks += uint32(data, position + 4)
                    }
                    indexDuration = Double(ticks) / Double(scale)
                } else {
                    var child = 0, tracks = 0
                    while child < data.count {
                        guard let atom = box(data, at: child, limit: data.count) else { return nil }
                        if atom.type == "traf" {
                            tracks += 1
                            var entry = atom.body.lowerBound
                            while entry < atom.body.upperBound {
                                guard let field = box(data, at: entry, limit: atom.body.upperBound) else { return nil }
                                if field.type == "trun" {
                                    guard field.body.count >= 8 else { return nil }
                                    packets += uint32(data, field.body.lowerBound + 4)
                                }
                                entry = field.body.upperBound
                            }
                        }
                        child = atom.body.upperBound
                    }
                    guard tracks == 1 else { return nil }
                    fragments += 1
                }
            }
            offset += size
        }
        guard fragments == referenced, let seconds = indexDuration,
              YouTubeAudioTimeline.agrees(seconds, Double(packets) * 1024 / sampleRate) else { return nil }
        return seconds
    }
}
