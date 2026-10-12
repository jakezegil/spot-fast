# Launcher design and process architecture

## Design review

Claude reviewed a general macOS launcher brief through the installed `claude` CLI. No source code or filesystem data was sent. The complete response is in [claude-design-review.md](claude-design-review.md).

The implemented design emphasizes predictable keyboard behavior, immediate local results, and a small initial window. The launcher expands downward when you type. Press Down to display pinned items, recent items, and common applications. Recent items remain hidden on first opening.

Rows use native application and file icons. All, Apps, and Files filters provide a consistent search scope. Selection follows the selected item's identity when asynchronous results arrive. After keyboard navigation, existing rows retain their order for that query. Typing a new query selects its highest-ranked result.

The search field uses the native text editor. Composition input keeps control of its navigation keys until composition finishes. Copy, paste, selection, and undo use native responder actions. The launcher uses a nonactivating panel to preserve the previous application's focus.

Quick Look loads only when you request a preview. Actions support opening, revealing, previewing, copying paths, and pinning. Appearance follows macOS or your explicit light or dark preference. Materials and semantic colors follow accessibility settings. Window resizing uses no animation.

## Settings

Open Settings through the gear button, Command–Comma, or the menu bar icon. Settings use a separate native window.

| Page | Controls |
| --- | --- |
| General | Global shortcut, query retention, macOS startup settings, keyboard guide |
| Search | Sources, web search engine, hidden files, excluded result folders |
| Appearance | System, light, or dark appearance; compact rows |
| Privacy | Local usage history, history removal, permission information |
| Index | Service status, entry counts, index size, service restart |
| About | Version, local diagnostics, upstream source link |

Usage history stores at most 100 opened application or file locations for 90 days. It stores timestamps and open counts. It does not store queries, contents, calculation values, or web URLs. The history file has mode 0600 inside the private support directory. Excluding a folder removes its items from history. Disabling history removes its ranking influence and stops new records.

Folder exclusions filter launcher results from every source. They do not remove entries from FSearch's stored index. Disabling filename search stops launcher requests; the background service remains running. These distinctions appear in Settings.

## Process decision

Keep the launcher and FSearch as separate user processes for this installation. They are not required to be separate for functional correctness.

This Mac's index contains about 14.6 million entries and occupies about 290 MB on disk. FSearch owns the index, background scanning, and filesystem events. Keeping that work separate contains daemon crashes and permits independent service restarts. The launcher retains application search, calculations, and Apple metadata search during a restart.

Both processes use the same account and lack App Sandbox containment. The split provides no privilege boundary. Socket permissions and peer checks reject other users; they do not authenticate individual same-user applications.

The existing user login agent supervises FSearch. The launcher starts independently and connects through the bounded filename-only socket protocol. Settings can restart FSearch without restarting the launcher. There is no root service.

An embedded XPC service remains a possible future packaging change. It requires a defined lifecycle and explicit sandbox permissions. Apple's [XPC documentation](https://developer.apple.com/documentation/xpc) describes process separation and communication.

## Verification

Run the Swift tests outside a restricted socket sandbox:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --scratch-path .build --cache-path .build/cache
```

Run the GUI smoke check from the repository after building:

```sh
dist/SpotFast.app/Contents/MacOS/SpotFast --ui-smoke-test
```

The GUI check renders its own windows. It does not register a global shortcut or alter preferences. It checks calculator results and category filtering. Render artifacts are written to `.build/ui-smoke`. Native layer-backed controls can be omitted from bitmap captures; screenshots alone do not verify keyboard behavior.

Run `python3 scripts/verify_runtime.py` to check the installed shortcut and real filename search.
