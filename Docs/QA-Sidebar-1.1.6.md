# 1.1.6 compact sidebar

Date: 2026-10-27. Version 1.1.6 (46), macOS 26, Apple Silicon.

## Behavior

- Command-/ switches between the expanded sidebar and a 60 pt icon rail. From fully hidden, it reveals the expanded sidebar.
- Command-. hides the sidebar independently; repeating it restores the preceding expanded/compact mode and retained expanded width.
- Compact rows retain the existing favicon provider, selection, context menus, reordering, detachment, and window-transfer model. Inline actions move to the context menu.
- Hovering a compact row schedules a Liquid Glass title tooltip after 300 ms. Leaving, scrolling, starting a drag, opening an address palette, clicking, typing, or deactivating the window cancels it.
- The View menu and localized help describe the two separate actions. Command-. no longer also invokes Stop Loading.
- Geometry and tooltip transitions use the existing spring animations and respect Reduce Motion.

Design measurements were read from Pico `391:485` and tooltip `393:673`: 60 pt rail, 36 pt rows/top controls, 12 pt insets, 32 pt bottom controls, 28 pt tooltip with 11 pt text.

## Automated verification

`swift test --no-parallel`: 305 tests across 45 suites; 300 passed, five pre-existing password event-loop cases skipped, zero failures. Log: `.build/sidebar46-tests.log`.

Targeted coverage includes sidebar state sequences, legacy session decoding, malformed optional preferences, width preservation, detached-window inheritance, compact drop regions, scrolled destination indices, existing tab-transfer behavior, and tooltip delay/cancellation races. Tooltip timing uses a monotonic clock and confirms presentation cannot precede 300 ms.

The release build completed and strict signature verification passed. The installed app's main executable and MCP helper match the build byte for byte. The DMG and ZIP were unpacked and verified against the same build. The package remains ad hoc signed, without Developer ID signing or Apple notarization.

## UI observations

In an isolated QA app, the expanded/compact/hidden transitions, compact reorder, tab context menu, drag-out detachment, window titles, and both light/dark layouts were exercised. Compact reordering changed the inspected list order, and detachment created an independent compact window.

In the final installed `/Applications/Nous Browser.app`:

- Command-/ visibly changed the sidebar to the 60 pt rail.
- Compact → Command-. → hidden → Command-. returned to the compact rail.
- Expanded → Command-. → hidden → Command-. restored the expanded sidebar at its previous width.
- The View menu displayed separate Collapse/Expand Sidebar and Hide/Show Sidebar actions.
- After installation, all 15 original tab IDs and their order, plus the selected tab, matched the saved pre-install session. Test content used a separate window.
- Capture: `.build/sidebar46/installed-compact.jpg`. Dark isolated capture: `.build/sidebar46/dark-compact.png` (JPEG encoded).
- The user physically hovered a compact tab in the installed build and explicitly confirmed that the glass title tooltip appeared normally and disappeared on pointer exit. The separate test window was then closed, restoring the original work window.

## Installed cross-window acceptance

Completed on 2026-10-27 using the installed 1.1.6 (46), two separate test windows, and local synthetic pages. macOS Window → Move & Resize placed the target on the left and source on the right. Each drop was performed through native pointer dragging; the resulting accessibility tree and persisted session were inspected. No test used the model's transfer method as a substitute for a native drag.

| Case | Observed result |
| --- | --- |
| Compact → compact, insert between two tabs | Target order became QA 1, QA 3, QA 2; the emptied source window closed. Total open windows dropped from three to two, including the untouched work window. |
| Expanded → compact, insert in the middle | Target order became QA 1, QA 3, QA 4, QA 2. Text entered into QA 4 before the drag remained in its textarea after transfer and after subsequent selection/mode changes. |
| Compact → expanded, insert second | Target order became QA 1, QA 5, QA 3, QA 4, QA 2; target remained expanded. |
| Pinned compact tab → expanded target | QA 6 retained its Pinned state and was inserted before normal tabs. QA 7 remained in its source window, whose title reflected the remaining selected tab. |
| Expanded → expanded, append | QA 7 appeared after QA 2; its now-empty source window closed. Final target order: pinned QA 6, QA 1, QA 5, QA 3, QA 4, QA 2, QA 7. |

The selected tab and window title followed each moved page. The final post-drop observations showed a settled row with no lingering duplicate drag image. An initial attempt detached a tab instead of hitting the intended destination; this was not counted as a pass. After explicitly activating and checking the destination window, the native drop was repeated successfully at the verified row position.

Local captures: `.build/sidebar46/compact-cross-window-pass.jpg`, `expanded-to-compact-pass.jpg`, `compact-to-expanded-pass.jpg`, and `all-transfers-pass.jpg` in the same directory. After closing the QA window, exactly the original work window remained; original tab IDs, order and selected ID matched the pre-test backup.

## Verification scope

The native UI automation interface cannot move the pointer without clicking or dragging. The 300 ms threshold is covered by the timing test; appearance and disappearance were accepted through the user's physical hover check, not a synthetic click.

The successful native tests cover the four expanded/compact combinations, insertion order, pinned-state preservation, page state, source-window lifetime and titles. They do not constitute a frame-time benchmark or coverage of every multi-display arrangement. Timing/geometry tests, native interaction and post-animation inspection provide separate evidence.
