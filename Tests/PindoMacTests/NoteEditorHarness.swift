import AppKit
import SwiftUI
import XCTest
import MarkdownEngine
@testable import Pindo

/// Uses the same hosting view, wrapper and bridge as the real note page.
@MainActor final class NoteEditorHarness {
    final class Buffer { var text: String; init(_ text: String) { self.text = text } }
    let buffer: Buffer
    let bridge: NoteEditor.Coordinator
    let host: NoteEditorHost
    let window: NSWindow
    var view: NSTextView { bridge.textView! }

    private init(_ text: String, font: PindoFontChoice) {
        _ = NSApplication.shared
        let buffer = Buffer(text)
        self.buffer = buffer
        let editor = NoteEditor(text: Binding(get: { buffer.text }, set: { buffer.text = $0 }), fontChoice: font)
        bridge = editor.makeCoordinator()
        host = NoteEditorHost(rootView: bridge.editor())
        host.bridge = bridge; bridge.host = host
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
    }

    static func make(_ text: String, font: PindoFontChoice = PindoFontChoice()) async throws -> NoteEditorHarness {
        let editor = NoteEditorHarness(text, font: font)
        let expected = WikiLinkService.makeDisplayState(from: text).display
        for _ in 0..<300 {
            editor.host.layoutSubtreeIfNeeded()
            editor.bridge.attach()
            if let view = editor.bridge.textView, view.string == expected, view.delegate is NativeTextViewCoordinator {
                await editor.settle()
                return editor
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        editor.close()
        throw NSError(domain: "PindoTests.NoteEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "MarkdownEngine did not mount its TextKit 2 editor"])
    }

    func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    func close() {
        window.makeFirstResponder(nil)
        bridge.commit(); bridge.stop()
        host.bridge = nil
        window.contentView = nil
        window.orderOut(nil)
    }
}
