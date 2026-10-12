# Launcher Ranking Redesign: Critique and Minimal Spec

## Verdict

The direction is right. The main risk is implementation as additive bonuses on one 0–1000 scale. Usage, app bonus and penalties will keep interacting unpredictably, and you will get the same inversions back. Use **ordered bands with clamped within-band adjustments**. Penalties may move items across bands. History never can.

## 1. Core structure

```
score = bandBase(matchKind, isApp, intent)
      + clamp(quality + usage, 0, bandWidth - 1)
      - penalty(pathClass, scope, query)
```

- **quality**: shorter name, earlier match position, case-exact, fewer path components (0–20).
- **usage**: `min(25, 8·ln(1+opens)·recencyDecay)`. The half-life is about 14 days. Count only opens whose name matched the current query at word-prefix or better.
- **Tie-break**: score, then matchKind, then shorter display name, then shallower path, then a stable lexical path. Never use arrival order.

**Is-app is a property of the item, not the provider.** Classify an item as an app if it is a `.app` bundle (or has an application-bundle content type) and is not nested inside another bundle. Dedupe apps by resolved path (including firmlinks) and then by bundle ID. Score display name, bundle name and filename stem, and take the best. This fixes "found by file provider, missed app bonus."

## 2. Bands (All scope, default intent)

| Band | Match | Score |
|---|---|---|
| A1 | App exact name (folded) | 950–999 |
| A2 | App whole-word token, or name-prefix ≥3 chars | 880–940 |
| F1 | File exact name or exact stem | 820–870 |
| A3 | App word-prefix ≥2 chars, initials ≥2 chars, or ordered multiword token-prefix | 760–810 |
| F2 | File name-prefix / whole-word | 690–750 |
| F3 | File word-prefix | 620–680 |
| A4/F4 | Substring at word boundary (apps +20) | 540–600 |
| F5 | Mid-token substring, apps and files | 450–500 |
| S | Subsequence, query ≥3 chars, compact (span ≤ 2×len) | 250–350 |

Apps and files share band S, with apps getting +15. Non-compact subsequences are dropped.

Why A2 sits above F1: "chrome" should open Google Chrome, not `~/Library/Application Support/Google/Chrome`. A3 sits below F1 because a 3-letter word-prefix of an app ("chr") is weaker evidence than a file named exactly what you typed.

**Tradeoff.** A user's own project folder named `chrome` loses to the app in All scope, no matter how often it is opened. I'd accept this, since the Files scope exists. Do not let history cross bands to "fix" it, or you rebuild today's bug.

**Incidental substrings.** "code" against Xcode or "Barcode Scanner" is mid-token (F5). "code" against Visual Studio Code is whole-word (A2). That is the behavior you want.

## 3. Query intent rules

Evaluate these in order and take the first that applies.

1. **Path intent.** The query contains `/` or starts with `~`.
   - Match against the full path, component-wise.
   - Apps compete only via A1.
   - Path penalties are bypassed for any component the query spells out.
2. **Extension intent.** The query ends in `.<ext>`, where ext is 1–6 alphanumeric characters and the stem is non-empty.
   - Files use bands F1–F3, raised above A2.
   - Apps drop to just below F1, so `Safari.app` still works.
   - Examples: `package.json`, `README.md`.
3. **Dotfile intent.** The query starts with `.`.
   - Treat as extension/file intent.
   - Bypass hidden-file penalty.
4. **Technical-component intent.** Any query token equals a known penalized component, e.g. `node_modules`, `.git`, `DerivedData`, `__pycache__`, `.venv`, `Caches`, `Pods`.
   - Bypass only that category's penalty.
   - Do not bypass the others.
   - Do not trigger on the generic word "cache". Require the exact component token. Otherwise "cache" as a project name would unblock everything.
5. **Default.** App-like intent, using the table above.

Short queries of 1–2 characters get only exact, name-prefix and initials matches. No substring or subsequence: they produce noise and waste the pool.

## 4. Path penalties (component-aware)

A penalty applies when the classified component is a **strict ancestor** of the item. The `node_modules` folder itself stays findable; its 40,000 descendants do not crowd results.

| Class | All | Files |
|---|---|---|
| OS internals (`/System`, `/usr`, `/private`, `/Library/Apple`) | −300 | −120 |
| Inside an app bundle (`*.app/Contents/…`) | −350 | −150 |
| Support data (`~/Library/Application Support`, `Containers`, `Group Containers`) | −200 | −80 |
| Caches/deps (`Caches`, `node_modules`, `DerivedData`, `.git`, `__pycache__`, `.venv`, `site-packages`, `Pods`, `.gradle`, `target/debug`?) | −300 | −100 |

Never penalize `vendor`, `build`, `dist`, `out`, `lib`, `src` or `Projects`. These are too often user-owned. Similarly, `target` is only penalized when paired with `debug` or `release`.

Penalize only the first-matching (strongest) class. Do not stack penalties: stacking makes small-path differences dominate.

**User-owned source.** If the nearest ancestor containing a `.git` directory is under the home directory and outside `~/Library`, mark the item user-owned. User-owned items get no support or OS penalty, but dependency penalties still apply inside them. Cache this per root. It's cheap, and it's the only "project awareness" you need.

## 5. README / stem matching

- Compute the stem by stripping the last extension, and only if the extension is ≤6 characters (avoids `v1.2.3`).
- An exact stem match lands in F1 alongside exact full-name matches.
- Within F1, add +10 quality if user-owned and +5 for a document-ish extension (`md`, `txt`, `rst`, `adoc`).
- System `README` files fall to around 520 via the OS penalty. `README.md` files in `node_modules` fall to around 520 via the dependency penalty. The project README stays at about 850.

## 6. Unicode and tokenization

- **Normalization.** Normalize both sides to NFC before anything else; APFS and HFS+ names often arrive NFD. Fold case and width using locale-independent folding; avoid Turkish İ/ı surprises.
- **Diacritics.** Fold diacritics for matching. Give a +3 quality bonus for an unfolded exact match, so "café" ranks `Café` above `Cafe`, but both match.
- **Tokens.** Use the system word tokenizer and additionally split on:
  - `-`, `_`, `.`, and whitespace
  - camelCase lower→Upper transitions
  - letter↔digit transitions
  - (So `VSCodeHelper` becomes `VS`, `Code`, `Helper`.)
- **CJK.** Treat tokenizer word boundaries as token starts. Allow prefix and substring matches, and disable initials. Optionally fold hiragana↔katakana.
- **Emoji and symbols.** Ignore them for tokens, but keep them for exact match.
- **Multiword queries.** Split the query the same way.
  - All query tokens prefix-matching name tokens, in order: A3 / F3.
  - Out of order: drop one band.
  - Any token unmatched: no match. Do not fall back to subsequence across a space.
  - So "visual code" matches Visual Studio Code in A3, and "studio vis" lands one band lower.
- **Initials.** First letter of each token, contiguous from token 1, query ≥2 chars. "vsc" matches Visual Studio Code; "gc" matches Google Chrome. Initials of only 2 characters collide widely; tie-break by usage, which is exactly where history should help.

## 7. Application prefix ambiguity

- **Vendor prefixes.** "microsoft" or "google" hits every vendor app at A2 (whole-word). That is correct; ordering comes from usage within the band, then the shorter name. Do not special-case vendor names.
- **Channels.** "chrome" matches Chrome, Chrome Beta, Chrome Canary and Chrome Remote Desktop at A2. Shorter name plus usage puts stable Chrome first unless the user actually uses Canary more. That is fine.
- **Helpers.** Apps nested in other bundles (e.g. "Chrome Helper (GPU)") are never apps for banding. They are bundle internals, and land below 600.
- **Installers.** `Google Chrome.dmg` in Downloads matches whole-word in F2, below the app.

## 8. Retrieval and pool starvation

- Raising the daemon pool to 100 helps, but post-filters can still empty it.
- Push hide filters into the daemon query where possible. Otherwise, if fewer than 10 survive after filtering, do **one** refetch at 300 and stop there.
- **Fetch apps separately**, from a small in-memory app index rebuilt on volume changes. Apps must never compete for slots in the file pool; this is the cheapest fix with the biggest effect.
- When the pool was truncated and filtered, say so in the UI ("more results in Files") rather than implying none exist.

## 9. Stable selection with async results

- Before any user navigation, results may reorder freely within roughly the first 150 ms.
- After an arrow key or mouse hover, or after 150 ms, freeze the visible ordering. Late arrivals insert only *below* the selected row. The selection stays bound to item identity, never index.
- Enter acts on what is visibly selected, never on a pending re-sort.

## 10. Ranking assertions (golden tests)

1. `chrome` → Google Chrome is #1; no Application Support folder appears above it.
2. `code` → Visual Studio Code is above every folder named `*code*`, and above Xcode.
3. `vsc` → Visual Studio Code is in the top 3.
4. `visual code` → Visual Studio Code is #1. `code visual` → Visual Studio Code is still in the top 5.
5. An app found only via the file provider ranks identically to the same app found via the app index, and appears once.
6. `README` with a user-owned project README.md plus 50 `node_modules` READMEs → the project README is above every `node_modules` one and every `/System` one.
7. `node_modules` → the project's `node_modules` folders appear in the top 5 in All.
8. `node_modules/react` (path intent) → `react` inside `node_modules` is #1.
9. `package.json` → user-owned `package.json` files precede `node_modules/*/package.json`.
10. `build` → a user folder named `build` gets no penalty and outranks an identically matching `build` under Caches.
11. **History cannot cross bands.** Open a mid-token match (F5) 1,000 times; it still ranks below an A2 match.
12. **History reorders within a band.** Chrome Canary opened 50× ranks above Chrome for `chrome`.
13. `cafe` matches `Café`; an NFD-named file matches an NFC query.
14. A 2-character query returns no subsequence-only matches.
15. A file named exactly `Chrome` (user-owned) is #1 for `chrome` in the Files scope.
16. Determinism: identical inputs in shuffled provider order produce identical output.

## What not to do

- No learned weights.
- No per-query click models beyond the "matched at word-prefix or better" filter on usage.
- No vendor dictionaries or stacked penalties.
- No penalizing ambiguous build-directory names.

Banding, item-based app detection, ancestor-only path classes, a separate app index and frozen selection cover every reported failure.
