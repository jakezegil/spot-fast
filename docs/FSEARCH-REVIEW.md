# FSearch hardening for SpotFast

## Source and scope

The source was obtained through the GitHub connector and pinned to commit `e96ebeb52545ea4facd4a4b3af393c42c980fb5d`. All 19 downloaded files matched their upstream Git blob hashes before modification. The source files, Cargo manifests, lockfile, and license are in `vendor/fsearch`. [Pinned upstream source](https://github.com/noahdunnagan/fsearch/tree/e96ebeb52545ea4facd4a4b3af393c42c980fb5d).

This work fixes identified boundaries in a local fork and adds a restricted launcher mode. It does not certify the entire upstream project or establish that all vulnerabilities are removed. No exploit was reproduced.

## Changes

| Boundary | Local change |
| --- | --- |
| Socket access | Private directory, socket mode 0600, peer-user verification on the server and client |
| Path and lock handling | Reject unsafe ancestors; open locks without following symlinks; reject hardlinks before truncation |
| Connection pressure | At most eight active connections; release permits on thread exit or spawn failure |
| Frame pressure | Bound frame allocation to 4 KiB; reject missing newline and invalid UTF-8 |
| Slow peers | One-second total frame deadline; bounded socket writes |
| Result pressure | Clamp results; reject oversized replies; client caps decoded results |
| Query surface | Dedicated filename, ping, and status operations; no content, MCP, git, frecency, or mutations |
| Content background work | Disable content indexing and discard its resync receiver to avoid queued work accumulation |
| Busy-spin behavior | Remove peer-driven keep-warm spinning from daemon handlers |
| Index arithmetic | Bound hostile counts and shifts before layout; checked layout addition; release overflow checks |
| Index references | Validate name ranges, entry IDs, parent bitmaps, directory relationships, packed-run shapes, and name-entry offsets |
| Typed views | Check slice length and alignment before constructing typed views |
| Packed reads | Replace unchecked pointer reads with checked byte-slice reads |
| Mapped files | Load private regular files into anonymous snapshots; disk truncation cannot invalidate pointers |
| Allocator | Use the standard Rust allocator in the daemon binary |
| Permissions | Refuse root launcher mode; force protected-folder exclusions; no Full Disk Access request |

The dedicated mode uses its own index directory and socket. It does not alter an existing upstream FSearch installation. The original CLI/MCP code remains vendored for traceability, but the installer starts only `serve-spotfast`.

The complete local diff is [fsearch-hardening.patch](fsearch-hardening.patch). The upstream license remains [MIT](../vendor/fsearch/LICENSE).

## Regression checks

Added Rust checks cover bounded frames, invalid UTF-8, symlink/hardlink lock attacks, hostile header counts, corrupt index references, safe packed-word bounds, snapshot survival after truncation, query limits, connection permits, and slow-peer deadlines.

Swift checks cover arithmetic, conversions, filename matching, malformed and oversized replies, response-profile verification, path sanitation, and live socket behavior. Python checks cover preserving unrelated preferences, restoring the previous app, and rejecting symlinked installer files.

Installation and verification completed on macOS 15.3.1 with Apple Silicon. All 20 Rust tests passed in release mode, including long multibyte filenames. The latest launcher passed all 30 Swift tests without skips. Six installer tests passed, including launchd shutdown waiting and bootstrap retries.

Cargo-audit checked 24 locked dependencies against 1,299 RustSec advisories and reported no vulnerabilities or warnings. The installed app signature verified. The daemon and app are running as user login agents. The live app reported successful Command–Space registration. Socket, index-directory, and lock-file modes are 0600, 0700, and 0600 respectively, owned by the current user.

A transient launchd update failure exercised rollback on this Mac. The previous working installation was restored before retrying with the shutdown-race fix. The original pre-install shortcut backup is preserved across upgrades.

The live index completed with 14,641,103 entries and 1,667,092 directories. A real temporary file was returned by filename search. The daemon rejected an oversized frame, remained responsive, and rejected content, pagination, work-budget, and mutating requests. Runtime status confirmed zero content documents and no Full Disk Access.

The installer runs release Rust tests, cargo-audit against the lockfile, Swift tests without skipped socket checks, signature verification, a native daemon probe, and live Command–Space registration verification. It makes no shortcut change before building and probing the daemon. Activation failure restores the saved installation.

## Remaining limits

The content parser is excluded from SpotFast's mode; it has not received a complete semantic validation audit. Library consumers and upstream CLI/MCP modes remain outside the activation claim. Native filesystem enumeration and FSEvents boundaries still require runtime stress and failure testing.

Peer-user verification cannot identify a particular same-user application. Protocol read and write deadlines do not interrupt arbitrary OS filesystem stalls or guarantee a name-search CPU deadline. The connection cap and restricted query surface bound concurrency.

Snapshot loading and full reference validation change index startup time and memory use. Performance, multi-user access, sleep/wake, crash recovery, and remount behavior require testing on this Mac. Automatic dependency updates, release signing, and notarization remain pending.

The launcher uses ordinary user permissions. Opening a file can launch its associated application. Installing a local fork does not establish a protected boundary against code already running as the same user.
