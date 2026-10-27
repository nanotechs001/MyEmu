import CoreGraphics

/// Parses `key=value` lines (AVD config.ini and engine discovery files).
func parseIni(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    return values
}

struct DeviceSize: Sendable, Equatable {
    let width: Int
    let height: Int

    struct Missing: Error {}

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(avdConfig: [String: String]) throws {
        guard let w = avdConfig["hw.lcd.width"].flatMap(Int.init),
              let h = avdConfig["hw.lcd.height"].flatMap(Int.init), w > 0, h > 0 else { throw Missing() }
        self.init(width: w, height: h)
    }

    /// Maps a point in a top-left-origin view that shows the screen aspect-fit to device pixels.
    /// Returns nil when the point is in the letterbox bars.
    func devicePoint(for point: CGPoint, in viewSize: CGSize) -> (x: Int32, y: Int32)? {
        let rect = aspectFitRect(content: CGSize(width: width, height: height), in: viewSize)
        guard rect.width > 0 else { return nil }
        let scale = rect.width / CGFloat(width)
        let x = (point.x - rect.minX) / scale
        let y = (point.y - rect.minY) / scale
        guard x >= 0, y >= 0, x < CGFloat(width), y < CGFloat(height) else { return nil }
        return (Int32(x), Int32(y))
    }
}

/// The largest rect with `content`'s aspect ratio, centered in `container` (letterboxed).
func aspectFitRect(content: CGSize, in container: CGSize) -> CGRect {
    guard content.width > 0, content.height > 0 else { return .zero }
    let scale = min(container.width / content.width, container.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                  width: size.width, height: size.height)
}
