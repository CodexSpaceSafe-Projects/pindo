import Foundation

/// A held shortcut fires once; the release arms it for the next deliberate press.
public struct HotkeyPressTracker: Sendable {
    private var pressed: Set<UInt32> = []
    public init() {}
    public mutating func update(id: UInt32, isDown: Bool) -> Bool {
        if isDown { return pressed.insert(id).inserted }
        pressed.remove(id); return false
    }
    public mutating func reset() { pressed.removeAll() }
}
