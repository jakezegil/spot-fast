# SpotFast

SpotFast is a native macOS launcher with application search, file search, document text search, arithmetic, conversions, dictionary, System Settings shortcuts, and web actions. It does not yet cover every Spotlight feature.

The source now connects to a dedicated hardened FSearch filename provider. Apple metadata supplies document text and fallback file results. Command–Space and FSearch are enabled by default in the app configuration. Actual activation requires the installation checks below.

## Install in one line

Requirements: macOS 13 or later, Xcode, Python 3, and Homebrew when Rust is missing. Run this in Terminal without sudo:

```sh
git clone https://github.com/jakezegil/spot-fast.git && cd spot-fast && python3 scripts/install.py --bootstrap-tools
```

Installation builds from source, installs missing Rust and cargo-audit tools, and runs security and regression checks. It installs SpotFast for your user, starts both login agents, and assigns Command–Space. The app is locally signed and is not notarized.

If you already cloned this repository, run `python3 scripts/install.py --bootstrap-tools` from its directory.

## Installation details

Setup performs these steps before changing your launcher:

1. Run the patched Rust tests under release optimization.
2. Check the pinned dependency lockfile with cargo-audit.
3. Build the patched FSearch executable and run Swift tests, including socket integration tests.
4. Build and sign the app with the patched daemon bundled inside it.
5. Back up the previous app, launch agents, and the Spotlight shortcut setting.
6. Install the app at `~/Applications/SpotFast.app` and start the private FSearch login agent.
7. Verify the daemon through SpotFast's actual client.
8. Disable Spotlight's Command–Space binding and enable SpotFast's binding.
9. Start SpotFast and verify that its live process registered Command–Space.

A failed activation restores the previous settings and installation. The installer preserves other keyboard shortcuts and Apple's indexing services. It uses macOS's internal shortcut activation utility; behavior across OS releases still requires verification.

Both processes start at login. Quit SpotFast through its menu to stop the launcher for the current session. Command–Q dismisses the launcher panel; it does not quit the background launcher. The daemon remains available until its login agent stops.

The app uses an ad hoc signature for local development. It is not notarized. No Full Disk Access, Accessibility, root daemon, or keyboard-monitoring permission is requested. Optional selected-folder access is granted through the native folder picker.

## Validation

Version 0.3.0 was tested on macOS 15.3.1 with Apple Silicon. The installed app registered Command–Space, and both user login agents ran successfully. The installed binaries matched the tested signed bundle.

Twenty Rust tests passed under release optimization. All forty-five Swift tests, including live socket tests, passed without skips. Six installer regression tests and three launcher-health regression tests passed. The pinned lockfile passed cargo-audit against 1,307 RustSec advisories, with no reported vulnerabilities or warnings.

Runtime checks verified private directory/socket/lock permissions, the dedicated endpoint, and native shortcut registration. Apple metadata returned the existing Safari application entry. Validation included a completed index containing more than 14 million entries. Live filename search returned the temporary verification file; request rejection and daemon recovery checks passed. Fresh scans can take several minutes on large filesystems. Protected folders remain excluded; no Full Disk Access was granted.

The original Spotlight rollback state remains saved across upgrades. Restore from the path recorded as `backup` in `~/Library/Application Support/SpotFast/installation.plist`.

## Restore the previous launcher

Setup prints the backup directory. Restore it with:

```sh
python3 scripts/install.py --restore "$HOME/Library/Application Support/SpotFast/backup-TIMESTAMP"
```

Replace `backup-TIMESTAMP` with the exact directory printed during installation. Restore changes only Spotlight's saved shortcut entry and SpotFast's two configuration keys. It preserves later changes to other shortcuts. The previous app and launch agents are also restored.

## Build without installation

```sh
python3 scripts/install.py --bootstrap-tools --build-only
```

This validates and bundles the daemon without changing macOS settings. To build only the launcher, run `bash scripts/build-app.sh`; that build does not bundle FSearch.

The Swift build uses `--disable-sandbox` to support managed build environments. The installed launcher and daemon use ordinary user permissions.

## Use the launcher

| Input or key | Behavior |
| --- | --- |
| `safari`, `vsc`, `chorme` | Match app names, initials, and small spelling errors |
| Configured aliases, such as `browser` | Open the application chosen for that alias |
| `readme ext:rs` | Search filenames through FSearch |
| `quarterly report` | Search filenames and indexed document text |
| `sound`, `volume`, `wifi`, `keyboard shortcuts`, `dark mode` | Open the matching System Settings pane |
| `microphone`, `camera`, `screen recording` | Open the corresponding privacy permissions page |
| `~/Downloads` | Open an existing path |
| `2 + 3 * 4`, `2^8` | Calculate locally; Return copies the result |
| `10 mi to km`, `32 f to c`, `1 gib to mib` | Convert locally; Return copies the result |
| `define ephemeral` | Open macOS Dictionary |
| `https://example.com` | Open the default browser |
| Any query | Offer Google search; send only when selected |
| Up / Down | Select a result |
| Return | Open or copy the selected result |
| Command–Return | Reveal a selected file in Finder |
| Command–K | Show actions for the selected result |
| Command–P / Command–Y | Toggle the selected file preview |
| Option–Command–C | Copy the selected file path |
| Command–1 through Command–9 | Open a visible numbered result |
| Tab / Shift–Tab | Change search category |
| Command–Comma | Open Settings |
| Down with an empty query | Show pinned items, recent items, and common apps |
| Escape | Close actions, preview, or launcher |

Open Settings with Command–Comma, the gear button, or the menu bar icon. Configure the shortcut, search sources, appearance, privacy, folder exclusions, and index service there. Pin items through their action menu. Choose a web search engine in Settings; queries are sent only when you open its result.

The launcher starts as a compact bar and expands when you type. Existing rows keep their order after keyboard navigation. Local usage history improves ranking without retaining queries. Ranking favors strong app-name matches, matches filename stems, and demotes recognized caches, dependencies, SDKs, simulator data, and system internals. Files mode uses smaller path penalties. See [the ranking review](docs/RANKING-REVIEW.md), [the design and process decisions](docs/UX-AND-PROCESSES.md) and [Claude's review](docs/claude-design-review.md).

## File coverage, aliases, and app discovery

Open Settings → Search to see which file providers cover each area. FSearch still skips protected folders and other mounted volumes. Apple's metadata search supplies permitted indexed results from those locations; its coverage depends on macOS indexing and privacy settings.

For additional filename coverage, choose **Add folder to search…**. Select Desktop, Documents, Downloads, a cloud folder, or a mounted drive. SpotFast retains read-only folder bookmarks and indexes names in its own process. This index stays in memory, skips package descendants and directory symlinks, respects exclusions, and refreshes every minute. It accepts at most 16 selected folders and 100,000 names total. Settings reports partial indexes, unavailable folders, and scan limits. Broad roots such as the whole home directory are rejected. Individual filesystem operations can still wait on an unresponsive mounted filesystem; scanning runs away from the UI thread.

Application aliases are configured on the same page. Choose an app and an alias, such as `browser` or `editor`. Exact aliases take priority in All and Apps; they do not affect Files. Aliases remain configured if their target disappears, so you can reconnect a drive or remove the alias yourself.

App spelling correction handles bounded insertions, deletions, substitutions, and adjacent swaps, including `chorme`. Correct app-name matches retain stronger priority. Automatic discovery watches application directories and nested non-package folders, refreshes on volume/application events, and performs a 30-second fallback scan. Installing or removing ordinary applications no longer requires restarting SpotFast.

## FSearch security boundary

The vendored source is pinned in [UPSTREAM.json](vendor/fsearch/UPSTREAM.json). Review the changes in [fsearch-hardening.patch](docs/fsearch-hardening.patch) and [the security report](docs/FSEARCH-REVIEW.md).

SpotFast connects only to `~/Library/Application Support/SpotFast/FSearch/fsearch.sock`. The directory is private, the socket belongs to the current user, and the response identifies the dedicated launcher profile. A preexisting upstream FSearch daemon is not reused.

The daemon accepts filename queries, ping, and status. It rejects content operators, regular expressions, git fields, pagination, and mutating requests. It allows at most eight connections, limits request frames to 4 KiB, and imposes an absolute one-second frame deadline. Queries use at most 16 words and 100 results. The app requests up to 100 filename candidates before ranking and displaying at most 60 results and enforces an 800 ms transport deadline and a 1 MiB response limit.

The daemon skips protected folders even if it inherits broader access. Apple metadata can supply permitted document results. Initial disk indexing runs in the background; Apple results remain available during indexing.

Index loading checks counts and internal references before use. It copies files into anonymous maps to prevent later disk truncation from invalidating pointers. This changes memory use and startup cost; benchmarks remain pending.

Same-user checks do not authenticate individual applications. Another process running as you can reach the socket. The launcher and daemon run with ordinary user permissions and are not App Sandbox-contained.

## System Settings shortcuts

Search for a pane name or a common alias, then press Return to open that pane. Examples: `sound`, `volume`, `display`, `wifi`, `keyboard shortcuts`, `disk space`, and `dark mode`. Use `settings sound` or `sound settings` to make the intent explicit. These results appear in All mode; Apps and Files keep their existing scope.

SpotFast checks installed Apple settings bundles and hides unavailable panes. Settings → Search includes a toggle for this source. Deep links only navigate: they do not change volume, network connections, privacy permissions, or other settings. No Automation permission is required.

The links use the URL scheme registered by System Settings. Pane identifiers and privacy anchors follow [Chromium's System Settings integration](https://chromium.googlesource.com/chromium/src/base/+/121663451b5528be114956be2c939ecc1d31551b/mac/mac_util.mm#442) and Apple-installed bundle metadata. Sound's visible pane was verified locally. Additional pane identifiers were checked against installed Apple bundles. URL handling can change between macOS versions; pane availability does not guarantee every route on every release.

## Remaining Spotlight coverage

Inline dictionary definitions, mail, contacts, calendar, reminders, currency rates, weather, Shortcuts, and system actions remain pending. Public API parity with Apple's private suggestion and app-search services is not established.

## Verify the running installation

```sh
python3 scripts/verify_runtime.py
```

The check creates and removes a temporary file inside this repository. It waits for real filename results and verifies request rejection and shortcut registration. Run it outside a restricted shell sandbox.

## License

SpotFast is available under the [MIT License](LICENSE). Vendored FSearch retains [its upstream MIT License](vendor/fsearch/LICENSE) and copyright notice.

## GUI integration checks

After building, run `python3 scripts/smoke_ui.py`. The helper uses a separate bundle identifier and in-memory settings. It checks aliases, spelling correction, selected-folder search with both other file providers disabled, and the launcher views. It does not register a global shortcut or modify the live app's preferences.
