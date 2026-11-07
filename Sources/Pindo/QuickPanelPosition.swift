import AppKit

/// Store the top-left anchor, so expanding a note changes height without moving
/// the header. Restore across launches and clamp if a display has been removed.
struct QuickPanelPosition {
    private let defaults: UserDefaults?
    private static let key = "PindoQuickAddTopLeft"
    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    func save(frame: NSRect) {
        defaults?.set(["x": frame.minX, "top": frame.maxY], forKey: Self.key)
    }

    func restoredOrigin(size: NSSize, visibleFrames: [NSRect]) -> NSPoint? {
        guard let values = defaults?.dictionary(forKey: Self.key),
              let x = values["x"] as? Double, let top = values["top"] as? Double,
              x.isFinite, top.isFinite else { return nil }
        return clampedOrigin(frame: NSRect(x: x, y: top - size.height, width: size.width, height: size.height), visibleFrames: visibleFrames)
    }

    func clampedOrigin(frame: NSRect, visibleFrames: [NSRect]) -> NSPoint? {
        guard let area = visibleFrames.max(by: { overlap(frame, $0) < overlap(frame, $1) }) else { return nil }
        return NSPoint(x: max(area.minX, min(frame.minX, area.maxX - frame.width)),
                       y: max(area.minY, min(frame.minY, area.maxY - frame.height)))
    }

    private func overlap(_ frame: NSRect, _ area: NSRect) -> CGFloat {
        let intersection = frame.intersection(area)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
