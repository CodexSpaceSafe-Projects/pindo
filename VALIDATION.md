# Validation record

Development environment: Linux x86_64, Swift 6.0.3 in Swift 5 language mode. The official toolchain's detached signature was verified using the Swift 6.x release signing key from the Swift project's official repository before use.

| Check | Result |
| --- | --- |
| `PindoCoreTests` | **19 executed, 0 failures** |
| Core production configuration | `swift build -c release` passed |
| Native Swift sources and macOS test syntax | Swift frontend parse passed; this is not macOS type checking |
| App Info.plist | Parsed and required bundle, UI element, executable and minimum-system fields checked |
| Packaging script | `bash -n` passed |
| macOS workflow structure | YAML parsed; macOS runner and build/test steps configured |
| AppKit/SwiftUI macOS compilation | **Not run**: macOS SDK/Xcode unavailable here |
| Five `PindoMacTests` | **Not run**: macOS required |
| Application bundle, macOS signature, login item, global shortcuts, Codex activation | **Not run**: require a Mac |
| GitHub Actions macOS job | Configured, not triggered or claimed successful |

The 19 executed tests cover: Unicode and compact note deltas; mismatched-patch rejection; snapshot restoration of note/phase/group/order; 100-snapshot retention; byte-budget compaction and oversize rollback; separate primary versus archive writes; real file round-trip; primary/backup corruption preservation; write-failure handling; recovery-before-restore protection; interrupted transaction replay; import protection; cross-day parallel phases and scoped rollover; leap-day/DST navigation; handoff text; invalid/duplicate/reserved hotkeys.

Linux test execution used writable package and module cache paths under `/tmp` because this machine's home cache is read-only. Those cache overrides are not required on a normal Mac.

Before native acceptance, run the README's Mac commands. The CI launch check only establishes that the process remains alive; manually verify the menu bar, note editing and outside return, settings, both hotkeys, input methods, focus restoration, multi-screen positioning, two parallel Codex handoffs, login approval, and snapshot recovery.
