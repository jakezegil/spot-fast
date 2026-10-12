# Search ranking review

## Evidence and consultation

The review compared eight searches through SpotFast's actual search model. It used current preferences, local usage history, FSearch, and Apple metadata. The queries covered Chrome, Safari, Notes, Terminal, Code, README, package.json, and Chrome in Files mode. No results were opened during inspection.

Claude reviewed a generic description of the failure patterns before implementation. No source code, local paths, or usage records were sent. Its complete response is in [claude-ranking-review.md](claude-ranking-review.md).

The review also consulted official launcher documentation. [Alfred describes application word-boundary matching and focused default results](https://www.alfredapp.com/help/features/default-results/). [Raycast describes fuzzy application search and frequency/recency ranking](https://manual.raycast.com/search-bar). These informed the design; neither source specifies SpotFast's score values.

## Behavior changes

| Search | Before | After |
| --- | --- | --- |
| chrome | Google Chrome at 17; cache folder first | Google Chrome first |
| safari | Safari at 14; support and dependency folders first | Safari first |
| code | Visual Studio Code at 53; Xcode at 52 | Visual Studio Code first; incidental app substrings lower |
| notes | Notes first | Notes first |
| terminal | Terminal first | Terminal first |
| readme | System README files above project README.md | Project READMEs above system and dependency files |
| package.json | Project files present | Exact file matches preserved; shallower paths break ties |
| vsc | Homebrew terminal resource above the editor during review | Visual Studio Code first; installed resources demoted |
| chrome, Files scope | Cache folders led | Source files stay findable; smaller penalties for technical paths |

Safari's installed link has macOS's hidden flag. The app scan now includes top-level application bundles before traversing non-hidden folders. All providers use the same application scorer. Nested application helpers receive file treatment instead of application priority.

## Ranking rules

Matching normalizes Unicode and folds case, accents, and character width. Word matching also handles punctuation, camel case, and initials. Multiword queries can match nonadjacent name words. Reversed words receive weaker priority. Short queries do not produce arbitrary substring or subsequence matches.

| Match | Application base | File base |
| --- | ---: | ---: |
| Exact display name | 1400 | 1000 |
| Whole word | 1300 | 800 |
| Name prefix, at least three query characters | 1200 | 800 |
| Short name prefix, word prefix, or app initials | 900 | 700 for word prefix; 800 for name prefix |
| Incidental substring | 650 | 500 |
| Compact subsequence | 300 | 300 |

Files also receive exact-name priority for an exact filename-stem match. For example, `readme` matches `README.md`. Explicit extensions preserve full-filename matching.

Name quality contributes at most 20 points. Usage contributes at most 25 points; a pin contributes 15. These adjustments cannot bridge the unpenalized name-match ranges. Existing usage records remain usable. Disabling history removes its influence.

Path penalties demote recognizable dependencies, caches, application internals, support data, OS internals, simulator data, and versioned Go SDK distributions, and Homebrew Cellar resources. The strongest applicable penalty wins; penalties do not stack. Files mode reduces penalties to 40 percent. Explicitly naming a technical component bypasses that component's penalty. An existing explicit path retains priority.

Generic folders named `build`, `dist`, `src`, `vendor`, or `cache` receive no blanket penalty. The implementation does not scan Git repositories or read file contents to classify projects. Ordinary source files remain searchable.

Filename or path-shaped queries reduce application priority. Files mode excludes application results. Strong application word matches beat same-named folders in All mode; Files mode provides the direct alternative.

Equal scores prefer shallower paths, then shorter titles, then stable identifiers. After keyboard navigation, existing rows retain their order. A new query restores relevance ordering.

## Candidate retrieval and limits

The launcher requests up to 100 filename candidates instead of 30. This remains within the existing hardened daemon limit. The response-size limit and transport deadline remain unchanged. The displayed list contains at most 60 results and reserves space for the web action.

This improves the pool available for filtering and reranking. It cannot recover candidates outside the daemon's first 100 hits. Exclusions and hidden-file filtering still apply after retrieval. Broad queries may therefore omit otherwise relevant files. No automatic unbounded refetch or privileged indexing was added.

The implementation does not adopt Claude's suggested 300-result retry because it exceeds the daemon's reviewed limit. It also avoids per-query learning and filesystem scans for project ownership.

## Validation

Thirty Swift tests and twenty Rust tests passed. The dependency audit reported no vulnerabilities. Installer regression tests, GUI smoke checks, and live shortcut/file-search verification also passed.

Regression tests cover browser and editor relevance, filename stems, application initials, multiword queries, explicit file intent, Unicode, technical-path exceptions, nested helpers, personalization bounds, and simulator/SDK classification. Existing socket, calculator, conversion, and selection tests remain enabled.

The live comparisons retain raw result paths only in local `.build/result-inspector` artifacts. The report above contains no private file paths.

## Contacts follow-up, 0.4.1

The initial Contacts scores competed with app matches even for one-character prefixes. Plain words also matched email domains. The reported queries were `ch`, `chr`, and `chrome`.

Claude reviewed synthetic comparisons across app, file, and contact scores. The correction lowers broad contact matches and checks each query token against a distinct name token. This prevents repeated words from inflating relevance. Existing application typo correction remains unchanged.

| Contact match | Base score |
| --- | ---: |
| Exact email or full phone number, with recipient-shaped input | 1250 |
| Exact full name, at least three characters | 950 |
| Email prefix or phone prefix/suffix, at least seven digits for phones | 900 |
| Multiple distinct name-token prefixes, each at least two characters | 850 |
| Whole name token, at least three characters | 820 |
| Name or word prefix, at least three characters | 600 |
| Exact full name or token, one or two characters | 300 |
| Short prefixes, initials, or name substrings | 250 |
| Partial recipient address | 200 |

Phone matching requires at least four digits. Email matching requires an `@` and at least four characters. Plain words such as `mail` and `chrome` cannot match email domains. Contact substrings require three characters. Strong app matches remain above contact names; exact filename matches remain above full contact names. A whole contact-name token can beat a mere filename prefix.

Regression tests compare contacts with application and filename scores for `ch`, `chr`, and `chrome`. They also cover address intent, phone normalization, repeated tokens, full names, and reversed name tokens. The optimized 10,000-contact benchmark measured approximately 9 ms median and 12 ms maximum. Contact search stays off the UI thread and cancels obsolete queries.

The Messages handoff had two independent errors: the legacy-only application identifier and an opaque recipient URL. The installed Messages app uses `com.apple.MobileSMS`. It accepted `imessage://recipient` and displayed both a fictional phone number and a synthetic email address. No message was typed or sent. The isolated launcher smoke test checks the Return command, application resolution, and recipient dispatch.
