# Validation record

Current development environment: Linux x86_64, Swift 6.0.3 in Swift 5 language mode.

## Current change

| Check | Result |
| --- | --- |
| Platform-independent tests | **31 executed, 0 failures** |
| Native app and macOS tests | Swift frontend parse passed for arm64 macOS 14; **not macOS type checking or execution** |
| Patch whitespace | git diff --check passed |
| macOS build, application launch and visual interaction | **Pending** for the current UI changes |

Core coverage includes: snapshots and protected replacements at the real 30 MB boundary; corruption and interrupted recovery; default-group persistence and legacy document compatibility; Markdown blocks; shortcut press/release tracking; calendar month/year boundaries, leap days and daylight-saving transitions; daily counts including pending, in-progress and completed tasks.

The macOS tests cover model saving, task status, group-aware ordering and creation, explicit composer selection, pin callbacks, management search/edit/delete, stable marked-text composition across editor synchronization and live styling, and view construction. Panel regressions check floating level, nonactivating presentation and native resizing. Editor tests check rendered font attributes, raw source/selection/undo preservation and outside-click hit testing that excludes resize borders and other windows. Counts are checked against group filters. These tests execute in the corresponding [macOS workflow](https://github.com/CodexSpaceSafe-Projects/pindo/actions/workflows/macos.yml) after every push; Linux cannot execute them.

## Mac acceptance

Build and run with the README commands, then check:

1. Enable macOS menu-bar auto-hide. With an ordinary window of another app covering the screen, open the unpinned list by status icon and shortcut: it must appear above that window. Repeat after pinning/unpinning and with a completely occluded list. Move the pointer away, click another app, and switch with Command-Tab. Unpinned panels should close without keeping the menu bar visible.
2. Hold and release each shortcut, press it again, and switch between quick add and the list. A held key must not immediately toggle the new panel closed. Check shortcut conflicts too.
3. Pin the list, switch apps and Spaces, open settings, then unpin and click outside. Verify frontmost retention only while pinned, and positioning on multiple displays/full screen.
4. Resize the window from every edge at minimum and large sizes, reopen it, and check both light/dark appearances for corner fringes. Check long titles/group names, full-row section disclosures, the fixed composer and the bottom group dropdown. Open the calendar, navigate months and compare orange/green counts with filtered tasks on past/future dates.
5. Enter Chinese in notes. Leave a composition open for more than 600 ms and across a 30-second snapshot check; select candidates with keyboard and mouse. Verify that saving does not reset composition, caret or selection. Check undo/redo and returning by clicking header/footer/margins. Editor clicks, scrollbars, IME candidates and window resize handles must keep the note open.
6. Edit headings, bold/italic, strikethrough, link labels, quotes, lists and code blocks in place. Syntax should appear in the active paragraph and be subdued/hidden elsewhere. Text must stay local and raw Markdown must round-trip through save/restore; formatting must not add undo entries. Check quick-add notes and management notes too.
7. In Settings > 管理待办, search across old and future tasks and notes, filter by state/group, complete/reopen, edit, open notes and delete. Check login startup and snapshot recovery.

## Earlier native CI

[Successful historical run](https://github.com/CodexSpaceSafe-Projects/pindo/actions/runs/42206508251) validated commit e31dc33 on macOS 15 / Xcode 16.4: compilation, tests, arm64/x86_64 universal packaging, ad hoc signing, five-second process launch and artifact upload.

That run predates this panel/editor change and is not evidence that the current native code compiles or that the interaction issues are resolved on a Mac. Release artifacts use ad hoc signing without Developer ID signing or Apple notarization.
