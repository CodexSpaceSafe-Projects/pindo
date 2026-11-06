import AppKit
import SwiftUI

/// Watches only the date header; task-list scrolling and text selection stay native.
struct DayScrollMonitor: NSViewRepresentable {
    var onStep: (Int) -> Void
    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(); view.onStep = onStep; view.start(); return view
    }
    func updateNSView(_ view: MonitorView, context: Context) { view.onStep = onStep }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var onStep: (Int) -> Void = { _ in }
        private var monitor: Any?
        private var total: CGFloat = 0
        private var lastEvent: TimeInterval = 0
        private var lastStep: TimeInterval = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), abs(event.scrollingDeltaX) > 1 else { return event }
                let time = Date.timeIntervalSinceReferenceDate
                if time - self.lastEvent > 0.2 { self.total = 0 }
                self.lastEvent = time
                guard time - self.lastStep > 0.5 else { return nil }
                self.total += event.scrollingDeltaX
                if abs(self.total) > 35 {
                    self.onStep(self.total > 0 ? 1 : -1); self.total = 0; self.lastStep = time
                }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}
