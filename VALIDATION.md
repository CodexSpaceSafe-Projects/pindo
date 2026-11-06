# Validation record

Development environment: Linux x86_64, Swift 6.0.3 in Swift 5 language mode. The official toolchain's detached signature was verified using the Swift 6.x release signing key from the Swift project's official repository before use.

Native CI: macOS 15 with Xcode 16.4. [Verified successful run](https://github.com/CodexSpaceSafe-Projects/pindo/actions/runs/42206508251) for commit `e31dc33` on 2026-11-06. The run provides the universal application archive and checksum as the `Pindo-macOS-0.1.0` artifact.

| Check | Result |
| --- | --- |
| `PindoCoreTests` | **19 executed, 0 failures** |
| Core production configuration | `swift build -c release` passed |
| Native Swift sources and macOS test syntax | Swift frontend parse passed; this is not macOS type checking |
| App Info.plist | Parsed and required bundle, UI element, executable and minimum-system fields checked |
| Packaging script | `bash -n` passed |
| macOS workflow structure | YAML parsed; macOS runner and build/test steps configured |
| AppKit/SwiftUI macOS compilation | **Passed** in macOS CI, debug and release; release binaries built for arm64 and x86_64 |
| Five `PindoMacTests` plus core tests | `swift test --jobs 4` **passed** in macOS CI |
| Universal application bundle and ad hoc signature | **Passed**: `lipo` architecture verification, plist validation, codesign creation and strict verification |
| Process launch | **Passed**: packaged app remained alive for the five-second smoke check |
| Application archive and SHA-256 checksum | **Passed**: uploaded to Actions artifacts |
| GitHub Actions macOS job | **Passed**, linked above; version-tag Release publication configured but not exercised |
| Login item, global shortcuts, Codex activation and visual interaction | **Not manually verified**: require interaction on a Mac |

The 19 executed tests cover: Unicode and compact note deltas; mismatched-patch rejection; snapshot restoration of note/phase/group/order; 100-snapshot retention; byte-budget compaction and oversize rollback; separate primary versus archive writes; real file round-trip; primary/backup corruption preservation; write-failure handling; recovery-before-restore protection; interrupted transaction replay; import protection; cross-day parallel phases and scoped rollover; leap-day/DST navigation; handoff text; invalid/duplicate/reserved hotkeys.

Linux test execution used writable package and module cache paths under `/tmp` because this machine's home cache is read-only. Those cache overrides are not required on a normal Mac.

Before interactive acceptance, run the README's Mac commands or download the CI artifact. The CI launch check only establishes that the process remains alive; manually verify the menu bar, note editing and outside return, settings, both hotkeys, input methods, focus restoration, multi-screen positioning, two parallel Codex handoffs, login approval, and snapshot recovery. Release artifacts currently use ad hoc signing, without Developer ID signing or Apple notarization.
