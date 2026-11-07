# Validation record

Current development environment: Linux x86_64, Swift 6.0.3 in Swift 5 language mode.

## Current change

| Check | Result |
| --- | --- |
| Platform-independent tests | **28 executed, 0 failures** |
| Native app and macOS tests | Swift frontend parse passed for arm64 macOS 14; **not macOS type checking or execution** |
| Patch whitespace | git diff --check passed |
| macOS build, application launch and visual interaction | **Pending** for the current UI changes |

Core coverage includes: snapshots and protected replacements at the real 30 MB boundary; corruption and interrupted recovery; default-group persistence and legacy document compatibility; Markdown headings, inline source preservation, lists, quotes, fenced code and CRLF; shortcut press/release tracking that suppresses held-key repeats.

The 13 macOS tests cover model saving, task status, group-aware ordering and creation, explicit composer selection, pin callbacks, management search/edit/delete, stable marked-text composition across editor synchronization, and view construction. Panel regressions check floating level before/after pin changes and nonactivating presentation. These tests are present but have not been executed in this Linux environment.

## Mac acceptance

Build and run with the README commands, then check:

1. Enable macOS menu-bar auto-hide. With an ordinary window of another app covering the screen, open the unpinned list by status icon and shortcut: it must appear above that window. Repeat after pinning/unpinning and with a completely occluded list. Move the pointer away, click another app, and switch with Command-Tab. Unpinned panels should close without keeping the menu bar visible.
2. Hold and release each shortcut, press it again, and switch between quick add and the list. A held key must not immediately toggle the new panel closed. Check shortcut conflicts too.
3. Pin the list, switch apps and Spaces, open settings, then unpin and click outside. Verify frontmost retention only while pinned, and positioning on multiple displays/full screen.
4. Click the blank parts of completed, unfinished and previous-task headers. Verify collapse/expand, the fixed add row, its independent group choice, and the bottom date control.
5. Enter Chinese in notes. Leave a composition open for more than 600 ms and across a 30-second snapshot check; select candidates with keyboard and mouse. Verify that saving does not reset composition, caret or selection. Check undo/redo, switching note modes, returning, closing and reopening.
6. Preview headings, bold/italic, links, quotes, task lists and code blocks. Text must stay local and raw Markdown must round-trip through save/restore.
7. In Settings > 管理待办, search across old and future tasks and notes, filter by state/group, complete/reopen, edit, open notes and delete. Check login startup and snapshot recovery.

## Earlier native CI

[Successful historical run](https://github.com/CodexSpaceSafe-Projects/pindo/actions/runs/42206508251) validated commit e31dc33 on macOS 15 / Xcode 16.4: compilation, tests, arm64/x86_64 universal packaging, ad hoc signing, five-second process launch and artifact upload.

That run predates this panel/editor change and is not evidence that the current native code compiles or that the interaction issues are resolved on a Mac. Release artifacts use ad hoc signing without Developer ID signing or Apple notarization.
