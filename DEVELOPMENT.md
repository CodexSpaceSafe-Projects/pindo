# Development notes

- Swift tools 5.9+, macOS deployment target 14. Swift 6 is supported in Swift 5 language mode.
- The app and native tests are declared conditionally in `Package.swift`; a Linux test run intentionally builds only the platform-independent core. Do not report that as a successful native build.
- Run `swift test --jobs 4`, then `bash scripts/build-app.sh` on a Mac before releasing. Existing checkouts are isolated; no additional worktree is necessary.
- No package dependencies or external services are needed. Never add credentials or session files to the repository.
- Repository mutations are serialized by `AppModel` on MainActor. Note staging does not write disk. Primary file saves are debounced; snapshot diff/compaction runs only during the 30-second check or explicit import/recovery.
- `data.json` and the bounded archive are separate files. Do not encode the archive into primary data on each keystroke.
- Recovery and import write a durable redo journal before replacing both files. A pending journal blocks further updates until replay succeeds. Do not delete a pending journal as a workaround for an error.
- Corrupt current data fails closed. Corrupt backup data is preserved and does not prevent saving the valid current document.
- The list uses a nonactivating NSPanel, with explicit outside-click and app-switch dismissal. Both pinned and transient panels use floating level and orderFrontRegardless when shown; never downgrade an unpinned panel to normal level. Pin controls dismissal and Spaces behavior. Avoid reintroducing an attached NSPopover or activating the app just to show the list.
- NoteEditor owns a stable NSTextView. Never replace its text or attributes while hasMarkedText() is true, and publish only committed text. Saving-state updates must not reset the selection or input method.
- Markdown renders live in the stable native editor. Keep raw source and UTF-16 indices in storage; update only text attributes, skip marked text, and preserve undo/selection. The active paragraph reveals its delimiters. Do not execute HTML or load remote images while parsing.
- The source-preserving TextKit approach was informed by [FSNotes TextStorageProcessor](https://github.com/glushchenko/fsnotes/blob/master/FSNotesCore/TextStorageProcessor.swift). Pindo's lightweight renderer is independently implemented and adds no dependency. It supports headings, emphasis, strikethrough, inline/fenced code, quotes, lists and link labels; it is not a full CommonMark layout engine.
- The task panel uses a native titled, resizable, nonactivating frame with full-size content, a 360 × 420 minimum and frame autosaving. WindowServer owns its rounded corners; do not add a second rounded mask around its hosting view.
- Source design and implementation are independent of the MIT reference projects. No source files or dependencies from those projects are bundled.
