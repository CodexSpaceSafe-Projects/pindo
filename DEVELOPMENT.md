# Development notes

- Swift tools 5.9+, macOS deployment target 14. Swift 6 is supported in Swift 5 language mode.
- The app and native tests are declared conditionally in `Package.swift`; a Linux test run intentionally builds only the platform-independent core. Do not report that as a successful native build.
- Run `swift test --jobs 4`, then `bash scripts/build-app.sh` on a Mac before releasing. Existing checkouts are isolated; no additional worktree is necessary.
- No package dependencies or external services are needed. Never add API keys or Codex session files to the repository.
- Repository mutations are serialized by `AppModel` on MainActor. Note staging does not write disk. Primary file saves are debounced; snapshot diff/compaction runs only during the 30-second check or explicit import/recovery.
- `data.json` and the bounded archive are separate files. Do not encode the archive into primary data on each keystroke.
- Recovery and import write a durable redo journal before replacing both files. A pending journal blocks further updates until replay succeeds. Do not delete a pending journal as a workaround for an error.
- Corrupt current data fails closed. Corrupt backup data is preserved and does not prevent saving the valid current document.
- A Codex handoff means copy, save manual in-progress status, then activate `com.openai.codex`. No automatic paste, send, installation, completion detection, or unverified thread deep link is implemented.
- Source design and implementation are independent of the MIT reference projects. No source files or dependencies from those projects are bundled.
