# Native macOS Launcher: UX, Visual-Design, and Architecture Handoff

**Target:** SwiftUI hosted in AppKit, macOS 13+. Tahoe (macOS 26) differences are noted where relevant.

**Thesis:** An excellent launcher meets four conditions:
- It is visible on the frame after the hotkey.
- Results never jump under the user's finger.
- Return always does what the screen showed.
- It looks like Apple shipped it.

Everything below serves those four rules.

---

## 1. Priority Interactions

Build in this order. Do not start a lower tier until the one above feels perfect.

| Tier | Interaction | Bar |
|---|---|---|
| P0 | Hotkey → panel visible, caret in field | ≤ 1 frame. The panel is pre-built and only ordered front, never created on demand. |
| P0 | Type → results | ≤ 16 ms p95 for the local index. Never blank the list between keystrokes. |
| P0 | ↑/↓ then ↩ opens the item | Selection is instant, with no animation. |
| P0 | Esc dismisses; focus returns to the previous app | Use a non-activating panel so the previous app never loses "active" status. |
| P1 | ⌘↩ Reveal in Finder, ⌥⌘C Copy Path, ⌘Y Quick Look | Use Finder's conventions. |
| P1 | ⌘K action menu, right-click menu | Both menus have identical contents. |
| P1 | Drag a row out to drag the file | Users love this. It is cheap with `NSItemProvider`. |
| P2 | Preview pane, recents, learned ranking | |

Two summon behaviors:
- **Re-summon:** Esc hides the panel but keeps the query for about 60 s. Re-summoning shows the old query fully selected, so typing replaces it and ↩ repeats the last open. This matches Spotlight.
- **Toggle:** pressing the hotkey while the panel is visible hides it.

---

## 2. Relevance

### Match tiers

Compute a deterministic score per candidate. The tier dominates; boosts only order items within a tier.

1. Exact name match (case/diacritic-insensitive, extension optional)
2. Name prefix
3. Word-boundary prefix (`"pho"` → "Adobe **Pho**toshop", camelCase, `-`, `_`, `.`)
4. Acronym / initials (`"vsc"` → **V**isual **S**tudio **C**ode)
5. Substring in name
6. Fuzzy subsequence in name, with contiguous runs scored higher
7. Path-component match (only when the query contains `/` or matches nothing in names)

### Boosts within a tier

- **Kind:** Applications > folders > documents > everything else. Apps get a large boost because "launcher" is the dominant intent.
- **Learned selection:** store `(normalized query prefix ≤ 4 chars) → item`, with counts decayed on a 7-day half-life. If you typed "sl" and chose Slack three times, Slack becomes the top hit for "sl". This is the single biggest perceived-intelligence win.
- **Frecency** of opens, decayed on a 14-day half-life.

### Penalties

- Path depth
- Anything inside `~/Library`, `node_modules`, `.git`, `DerivedData`, or a package bundle
- Hidden files (excluded by default)

### Tie-breakers

Apply in this order so results are fully deterministic:
1. Shorter name
2. More recent modification
3. Shallower path
4. Localized standard compare on display name

**Names:** match against `FileManager.displayName(atPath:)`, which is localized and extension-aware. For apps, also match `CFBundleName` and the filename.

### Stable selection

This is where most launchers fail.

Model selection as an **item identity plus a mode**, never as an index:

```swift
enum SelectionMode { case auto, manual }
struct SelectionState { var id: ResultID?; var mode: SelectionMode }
```

Rules:

1. **Query change resets to `.auto`.** In auto mode, selection follows the top result.
2. **Arrow keys, ⌘1–9, or an actual mouse move switch to `.manual`.** When results update for the same query:
   - If the selected ID is still present, keep it selected, wherever it moved.
   - If it vanished, fall back to the top result and `.auto`.
3. **Visible rows never reorder for the same query after first paint.** Results that arrive later (slow sources, index catch-up) may only append below the visible rows or into a lower section. If you have multiple sources, give each a 30–50 ms deadline and freeze what's painted.
4. **Return commits what's highlighted at key-down.** If a search is in flight, open the currently highlighted item. Do not wait for "better" results.
5. **Hover changes selection only on real mouse movement.** Track `NSEvent.mouseLocation` deltas. A row sliding under a stationary cursor because the list changed must not steal selection. Getting this wrong is the most common bug in this category.
6. **Between keystrokes, keep showing the previous results** until the new set is ready. As a cheap interim, filter the previous results client-side. An empty flash reads as broken.
7. **Use a generation counter** per keystroke and discard stale results.

---

## 3. Recents and Privacy

**Default posture:** local-only, minimal, and explicable in one sentence in Settings.

- **The empty state shows nothing** (see §5). Recents appear only when the user presses ↓ in an empty field. This keeps the panel compact and avoids exposing history during screen sharing or over-the-shoulder viewing.
- **What to store:**
  - Path, last-opened date, and open count, capped at 50 items or 90 days.
  - Learned prefix→item associations, capped and decayed.
  - Never full query history, file contents, or telemetry.
- **Where to store it:** `~/Library/Application Support/<bundle-id>/`, in a single file or SQLite DB with `0600` permissions.
- **Validate lazily.** Drop recents whose file no longer exists the moment they would be displayed.
- **Honor exclusions retroactively.** Adding an excluded folder purges matching recents and learned associations immediately.
- **Controls:**
  - "Remember opened items" toggle
  - "Learn from my selections" toggle
  - "Clear History…" button (single confirmation)
  - "Pause history" toggle, also available from the menu bar item
- **Network and removable volumes** are not indexed by default.
- **Full Disk Access is optional.** Without it, index what TCC allows and state plainly in Settings what is missing. Never nag from the panel.

---

## 4. Real Native Icons

Generic glyphs instantly mark an app as non-native. Use the real icons:

- **Per-file icons:** `NSWorkspace.shared.icon(forFile:)`. This returns real app icons, custom folder icons, and document icons with the badging Finder shows.
- **Instant placeholder:** `NSWorkspace.shared.icon(for: UTType)`, cached per type, painted immediately. Swap in the per-file icon when it arrives.
- **No layout shift:** the icon frame is fixed, and the swap happens without animation (a crossfade at 60 fps reads as flicker).
- **Cache:**
  - Key icons by `path + modification date`.
  - Use an LRU of about 500 entries.
  - Load on a utility queue and publish to main.
  - Set `image.size` to the display size before use.
  - In SwiftUI, use `Image(nsImage:).interpolation(.high)`.
- **Preview thumbnails:** `QLThumbnailGenerator`, requested only for the selected item and only after 80 ms of selection dwell. Cancel the request when selection moves, so arrowing through 30 rows generates nothing.

---

## 5. Layout and Metrics

**Use a fixed width** so the field never shifts horizontally. The window grows downward only, with the top edge anchored.

### Positioning

- **Screen:** the one containing the mouse. If you prefer, use the key window's screen, but be consistent.
- **Placement:** horizontally centered, top edge at 22% of `visibleFrame` height from the top.
- **No persistent dragging.** The panel always appears in the same place, which builds muscle memory.

### Compact (initial) state

| Element | Spec |
|---|---|
| Panel width | 720 pt |
| Field row height | 52 pt (this is the whole window in compact state) |
| Magnifier glyph | SF Symbol `magnifyingglass`, 18 pt, `secondaryLabelColor`, 16 pt leading inset |
| Field text | System font 22 pt regular, `labelColor`; text starts 12 pt after the glyph |
| Placeholder | "Search apps and files", `placeholderTextColor` |
| Trailing (optional) | Spinner only while the index is building, 12 pt, `tertiaryLabelColor` |

### Results state

| Element | Spec |
|---|---|
| Divider below field | 1 px `separatorColor`; appears only when results exist |
| List vertical padding | 6 pt top and bottom |
| Row height | 40 pt |
| Row horizontal inset | 6 pt (the selection rect is inset from the panel edge) |
| Selection rect | Corner radius 6 pt (≈ 8 pt on Tahoe); `selectedContentBackgroundColor`; text becomes `alternateSelectedControlTextColor` |
| Icon | 24 pt, 10 pt leading padding, 10 pt gap to text |
| Title | 13 pt regular (`.body`), single line, tail truncation; matched characters semibold (not colored) |
| Subtitle | 11 pt, `secondaryLabelColor`; path shown with `~`, **middle truncation** |
| Trailing accessory | `⌘1`…`⌘9` in 11 pt monospaced digits, `tertiaryLabelColor`; selected row shows "↩" instead |
| Section header | 11 pt semibold, `secondaryLabelColor`, 22 pt tall, 16 pt leading; not selectable (arrows skip it) |
| Sections | Top Hit · Applications · Folders · Documents · Other |
| Visible rows | Max 8; scroll beyond; list max height ≈ 360 pt |
| Footer | 28 pt, 11 pt `tertiaryLabelColor`; left: index status; right: `↩ Open  ⌘↩ Reveal  ⌘K Actions` |
| Max total height | ≈ 440 pt |

### Preview pane (optional, toggled with ⌘P, preference persisted)

| Element | Spec |
|---|---|
| Width | 300 pt on the right; list shrinks to 420 pt; 1 px vertical divider |
| Padding | 16 pt |
| Thumbnail | Fits within 268 × 180, aspect-fit, corner radius 6 pt; falls back to a 64 pt icon |
| Name | 15 pt semibold, up to 2 lines |
| Kind | 11 pt secondary |
| Metadata grid | Kind, Size, Created, Modified, Where. Labels 11 pt secondary, right-aligned; values 11 pt primary; 4 pt row spacing. Use `Grid` (macOS 13+). |

### Resizing

- Set the window frame directly, anchoring the top edge.
- Either animate with `NSAnimationContext` at 0.12 s ease-out, or skip animation entirely. Resizing every keystroke at 60 Hz looks janky, so only animate compact↔results transitions.
- Call `invalidateShadow()` after each resize.

---

## 6. Materials, Color, and Typography

- **Material:**
  - `NSVisualEffectView`, `.popover` material (test `.hudWindow` as an alternative), `.behindWindow` blending, `.active` state.
  - Window corner radius 12 pt on macOS 13–15, applied via `maskImage` or the visual-effect view's layer, with the system window shadow.
  - On macOS 26, adopt the system glass treatment behind an availability check rather than imitating it.
- **Colors:** semantic only (`labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `separatorColor`, `selectedContentBackgroundColor`). No hard-coded hex values. These colors handle light/dark, Increase Contrast, and accent color automatically.
- **Reduce Transparency:** `NSVisualEffectView` degrades automatically. Verify that your text still meets contrast against the opaque fallback.
- **Typography:** SF Pro via system fonts only. Use monospaced digits for shortcut hints and file sizes. Do not use custom fonts, tracking, or uppercase section headers; Apple uses sentence case.

---

## 7. Window and Text-Field Plumbing

These choices make the panel behave natively.

### Panel

```swift
final class LauncherPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false        // you manage hiding yourself
        isMovableByWindowBackground = false
        animationBehavior = .none        // you own the motion
    }
    override var canBecomeKey: Bool { true }
}
```

- **Hide on `windowDidResignKey`.** Clicking elsewhere dismisses the panel.
- **Hotkey:** register with Carbon `RegisterEventHotKey`, which needs no Accessibility permission. Default to **⌥Space**; never take ⌘Space from Spotlight.
- **Search field:** use an `NSTextField` wrapped in `NSViewRepresentable`, not SwiftUI `TextField`.
  - Route keys through `control(_:textView:doCommandBy:)`: `moveUp:`, `moveDown:`, `insertNewline:`, `cancelOperation:`, `insertTab:`.
  - Handle ⌘-chords in the panel's `performKeyEquivalent`.
  - This gives you correct IME, dictation, emoji picker, and undo behavior for free. On macOS 13, `FocusState` plus `onKeyPress` (14+ only) can't match it.
  - **IME rule:** while `hasMarkedText()` is true (CJK composition), ↩ and arrows belong to the input method. Do not intercept them.

---

## 8. Keyboard Shortcuts

| Key | Action | Notes |
|---|---|---|
| ⌥Space (configurable) | Toggle panel | |
| ↑ / ↓, ⌃P / ⌃N | Move selection | Wraps? **No.** Stop at the ends. |
| ⌘↑ / ⌘↓ | First / last result | |
| ⌥↑ / ⌥↓ | Previous / next section | |
| ⌘1–⌘9 | Open nth result | |
| ↩ | Open | |
| ⌘↩ | Reveal in Finder | |
| ⌥↩ | Open With… submenu | |
| ⌘Y | Quick Look (`QLPreviewPanel`) | Finder convention; Space would conflict with typing |
| ⌘P | Toggle preview pane | |
| ⌘I | Get Info (via Finder) | |
| ⌘C | Copy file | **Only when the field has no text selection**; otherwise copy text |
| ⌥⌘C | Copy path | Finder convention |
| ⌘K | Action menu | |
| ⌘, | Settings | |
| Esc | Close action menu, else dismiss panel | Query is retained for 60 s |
| Tab | Move to the next section | |

**Trash is deliberately not bound to ⌘⌫.** In a text field, ⌘⌫ means "delete to line start", and conflating the two will trash someone's file. Put Move to Trash only in the action menu.

---

## 9. Action Menu (⌘K and Right-Click)

- **⌘K** opens an inline, filterable list anchored to the bottom-right of the panel, about 260 pt wide, with the same row styling at 28 pt height. Type to filter, ↩ to run, Esc to return.
- **Right-click** shows a real `NSMenu` with the same items and key-equivalent hints.

Contents, grouped:
1. Open · Open With ▸ (default app first, then `NSWorkspace.urlsForApplications(toOpen:)`)
2. Reveal in Finder · Quick Look · Get Info
3. Copy · Copy Path · Copy Name
4. Open in Terminal (folders only; also available for files' parent folders)
5. Move to Trash

**Move to Trash:**
- No confirmation dialog. Use `NSWorkspace.recycle`, then show a 4-second inline toast: "Moved to Trash · Undo (⌘Z)".
- Undo moves the file back from the returned URL. Undo is better than a confirmation.

---

## 10. Motion

Keep motion restrained.

- **Appear:** opacity 0→1 plus scale 0.98→1 over 120 ms, ease-out.
- **Dismiss:** opacity to 0 over 80 ms, or instantly. Dismissal must never delay focus returning to the previous app.
- **Selection, row changes, icon swaps:** no animation. Instant.
- **Height change:** at most 120 ms ease-out, and only for compact↔results transitions.
- **Reduce Motion:** no scale; use opacity only, at 80 ms.

---

## 11. Errors and Edge States

All errors are inline and non-modal. Typing is never blocked.

| Situation | Behavior |
|---|---|
| Index building | Results appear progressively. Footer reads "Indexing… 184,203 items" with a small spinner. |
| No results | One row: "No results for "foo"", followed by actionable rows: "Search in Finder" (opens a Finder search) and "Search the web" (only if enabled). |
| File vanished at open | Remove the row, show the inline banner "Couldn't find "x" — it may have been moved or deleted", and drop it from recents. |
| Permission denied / no Full Disk Access | The footer chip "Some locations aren't searchable" opens Settings → Privacy, which has a button to the Full Disk Access pane. |
| Indexer crashed or restarting | Footer reads "Reconnecting to index…". Keep serving the last snapshot (see §14). |
| Open failed (no app) | Inline: "No app can open this file" with an **Open With…** affordance. |
| Hotkey conflict at registration | Shown in Settings next to the recorder, plus a one-time menu bar notice. |

Banner style: a 32 pt row above the footer, 11 pt text, `systemOrange`/`systemRed` SF Symbol, auto-dismissing after 5 s unless it contains an action.

---

## 12. Accessibility

- **Field:** label it "Search". It owns a results list, combobox-style.
- **Results:** expose the list as an accessibility list. Each row is labeled "Name, Kind, in ~/Path" with an "Open" action, plus custom actions mirroring the ⌘K menu (`accessibilityCustomActions`).
- **Selection changes:** keyboard focus stays in the field, so post an announcement on selection change (`NSAccessibility.post(… .announcementRequested …)`, medium priority), debounced to 150 ms. Also post a debounced result-count announcement ("12 results").
- **Never rely on color alone.** Selection is a filled rect plus a text-color change; matched characters use weight, not color.
- **Contrast:** secondary text must meet 4.5:1 on both material extremes. Test over white and black wallpapers with Reduce Transparency on and off.
- **Reduce Motion, Increase Contrast, Reduce Transparency:** handled per §6 and §10.
- **Full Keyboard Access:** every action menu item and Settings control is reachable without a mouse.

---

## 13. Settings Window

The app is `LSUIElement`. On macOS 13, the SwiftUI `Settings` scene is awkward to open from an agent app, so own the window:

- **Window:** `NSWindow` plus `NSTabViewController(tabStyle: .toolbar)`, with toolbar style `.preference`.
  - Each tab is an `NSHostingController` around a SwiftUI `Form` with `.formStyle(.grouped)`.
  - Fixed width of 560 pt; height animates per tab.
- **Opening it:** call `NSApp.activate(ignoringOtherApps: true)`. Optionally switch to `.regular` activation policy while Settings is open, so it appears in ⌘Tab, and revert on close.
- **Entry points:**
  - ⌘, from the panel
  - Menu bar item (if enabled)
  - Relaunching the app from Finder (`applicationShouldHandleReopen`). This is the essential escape hatch if the user hides the menu bar icon.

### Sections

| Tab | Contents |
|---|---|
| **General** | Hotkey recorder (with conflict warning) · Launch at login (`SMAppService.mainApp`, showing the `.requiresApproval` state with a button to `openSystemSettingsLoginItems()`) · Show menu bar icon · Show preview pane by default · Show footer hints |
| **Search** | Included locations list (+/−) · Excluded locations list (+/−) · Include hidden files · Search inside app/package bundles · Include external & network volumes · Result categories (toggle and reorder Apps/Folders/Documents) |
| **Privacy** | Remember opened items · Learn from my selections · Pause history · Clear History… · Full Disk Access status (✓ / "Not granted" + Open Privacy Settings) · A one-paragraph plain-English statement of what is stored and where |
| **Index** | Status (items, last full scan, live/paused) · Rebuild Index… · Pause indexing on battery · Approximate disk usage |
| **About** | Version · Acknowledgements · "Copy Diagnostics" (local text the user can paste; no automatic upload) |

**Controls:**
- Apply changes instantly; no Apply button.
- Destructive buttons say what they destroy: "Clear History…", not "Reset".

---

## 14. Process Architecture: One Process or Two?

### What a separate indexer process actually gives you

**1. Crash containment (real, and the main reason).**
- Filesystem walks hit weird things: deep symlink loops, enormous directories, flaky network volumes, and your own bugs in the parsing and persistence code.
- If the indexer dies, the panel stays up and keeps answering from the last snapshot. launchd relaunches the indexer, and the user may never notice.

**2. Responsiveness (real, but smaller than people assume).**
- Most of the responsiveness win is achievable in one process with a background actor or queue at `.utility`/`.background` QoS, plus I/O throttling (`setiopolicy_np` / background QoS).
- What a second process adds:
  - The UI process stays small (fast summon, less paging after the machine has been idle).
  - The indexer can be throttled or suspended as a whole.
  - Indexer memory spikes and heap fragmentation don't land in the process that must respond within one frame.

**3. Privilege isolation (usually not real; don't claim it).**
- Two unsandboxed processes running as the same user have **identical** power. Either can read everything the user can. Splitting them is not a security boundary.
- It becomes a boundary only if the processes have **different sandbox profiles or entitlements**. For example:
  - The indexer has file read access and no network.
  - The UI is sandboxed with no broad file access, and opens items by handing URLs to `NSWorkspace`. Verify this works for your open/reveal/trash paths under the sandbox; Trash and Get Info will fight you.
- Even then, a filename indexer's attack surface is small: it reads directory entries, not untrusted file contents. Thumbnails already render out-of-process via Quick Look. The security payoff is modest.
- **Validate IPC peers in either case:**
  - On macOS 14+, use `NSXPCConnection.setCodeSigningRequirement`.
  - On macOS 13, check the audit token with `SecCode` APIs.
  - This matters especially for a launchd Mach service, which any same-user process can try to connect to.
- **TCC caveat:** Full Disk Access attribution follows the "responsible process".
  - An XPC service embedded in your app is generally attributed to the host app (one grant).
  - A separately registered launch agent may need its own grant (two entries confusing the user).
  - Verify this empirically on each supported OS.

### Lifecycle options

| Option | Lifetime | Pros | Cons |
|---|---|---|---|
| **A. Single process**, background indexing actor | = app | Simplest, zero IPC, one TCC identity | An indexer crash kills the launcher (mitigated by fast reload of a persisted index) |
| **B. Embedded XPC service** (`Contents/XPCServices`) | Launched on demand by launchd, scoped to your app | Crash containment with auto-relaunch, separate QoS and memory, same TCC attribution, no extra approval, dies with the app, no version skew | launchd may reclaim it when idle, so the app must hold the connection to keep FSEvents live; must handle interruption and invalidation with reconnect plus resync |
| **C. Launch agent** (`SMAppService.agent`) | Independent of the UI; `KeepAlive` possible | Index stays live while the UI is quit | Separate Login Items entry the user must approve · version skew after updates (requires a protocol version and agent restart on upgrade) · possibly separate TCC grant · harder clean uninstall · exposed Mach service |

### Recommendation

- **Start with A, but structured for B.** Put the index behind an async `SearchIndex` protocol, with immutable result values and no shared mutable state.
- **Move to B** when you see crash reports or memory spikes from indexing. With that boundary in place, the move is mechanical.
- **Avoid C** unless you truly need indexing while the launcher is quit. A launcher that launches at login is effectively always running, so C's main benefit rarely materializes and its costs are permanent.

### Best-of-both pattern for B

Don't send queries over XPC per keystroke:
- The indexer writes **immutable, versioned snapshot files** (compact sorted name table plus a path table) and an append-only change journal, driven by FSEvents.
- The UI `mmap`s the current snapshot read-only and searches **in-process**, so there is no IPC on the keystroke path.
- XPC carries only control messages: "new generation available", status, rebuild, and pause.
- If the indexer crashes, the UI keeps searching the last snapshot. The worst case is slightly stale results, never a dead launcher.

For the initial scan, use `getattrlistbulk` (or `FileManager` enumerators with prefetched keys). Use FSEvents with a persisted event ID so relaunches resume incrementally instead of rescanning.

---

## 15. Acceptance Checklist

- [ ] Hotkey → caret blinking in ≤ 1 frame (panel pre-built, never re-created)
- [ ] Keystroke → painted results ≤ 16 ms p95 on a 1M-entry index; never an empty flash
- [ ] A row never moves under a stationary mouse; hover selects only on real movement
- [ ] ↩ during an in-flight search opens exactly the highlighted row
- [ ] IME composition is never hijacked
- [ ] Real icons everywhere, with no layout shift on icon load
- [ ] Correct in light, dark, Increase Contrast, Reduce Transparency, and Reduce Motion
- [ ] VoiceOver announces selection and result count; all actions are reachable by keyboard
- [ ] Killing the indexer process (or thread, under A) never takes the panel down (B) or recovers on relaunch in < 1 s (A)
- [ ] Clear History removes recents **and** learned associations; exclusions purge retroactively
