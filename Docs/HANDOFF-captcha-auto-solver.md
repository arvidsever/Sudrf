# Handoff: captcha-auto-solver branch (v0.38.0 → v0.38.6)

> Last updated: 2026-07-09 (between v0.38.6 and v0.38.7)

## Repo & branch

- **Repo:** `/Users/arvidsever/Claude/Projects/Sudrf`
- **Branch:** `captcha-auto-solver` (off `codex-captcha-assist`)
- **Remote:** `origin/captcha-auto-solver` (synced)
- **All v0.38.x commits pushed.** Working tree is clean on `captcha-auto-solver`.

## State summary

A `CaptchaSolver` SwiftPM product was added in v0.38.0 to auto-solve sudrf captchas via Apple Vision. After 6 quick fix-cycles the auto-solver works on some courts (e.g. `ramenskoe--mo.sudrf.ru`) and the diagnostics flow is now correct. The user's open problem is that `sankt-peterburgsky--spb.sudrf.ru` (spb) and `oblsud--mo.sudrf.ru` (mo) still fail.

**Test count: 270, 0 failures.** Built clean.

## What's in each version

| Version | What it does |
|---|---|
| **v0.38.0** | New `CaptchaSolver` SwiftPM product (Vision-based OCR). `RefreshCenter.tryAutoSolve` wired in for background refresh. Manual sheet becomes fallback. |
| **v0.38.1** | Auto-solver wired into interactive `SearchModel.runSearch`. `executeSearch(allowAutoSolve:)` + `handleCaptcha(...)` flow. |
| **v0.38.2** | Auto-solver wired into per-instance captcha stubs in `CaseMovementView` via `AppRouter.beginCaptcha(for:)`. Third cassation path. |
| **v0.38.3** | **Log fix** (`FileHandle(forUpdating:)` + `seekToEnd()` — `forWritingTo` was overwriting from offset 0). **`logFailedImage(...)`** writes failed captcha PNGs to `~/Library/Application Support/Sudrf/captcha-failures/`. FIFO 50 files. |
| **v0.38.4** | `Preprocessor` (grayscale + contrast + 2x scale) per-host gated. Default OFF — regresses easy cases ("667" → "49"). `CaptchaSettings.preprocessorHosts: Set<String>` for opt-in. `minimumTextHeight` 0.3 → 0.2. |
| **v0.38.5** | `SearchDiagnostics` (HTML dumper for failure paths). Writes to `~/Library/Application Support/Sudrf/diagnostics/`. Three paths: `dumpFormCheck`, `dumpVariant`, `dumpSolverMismatch`. Toggle: `defaults write ru.sudrf.app captcha.diagnosticsEnabled -bool NO`. |
| **v0.38.6** | **Diagnostic dump preserves raw bytes** (no re-encoding). The v0.38.5 dump was `String.data(using: .utf8)` → mojibake when server sent cp1251. v0.38.6 writes raw bytes. New `data:` overloads + `SudrfClient.fetchHTMLData`. |

## Open problem (not fixed)

The user reports:
- **spb (St. Petersburg City Court)**: works at first because the auto-solved token is stored in `CaptchaTokenStore` (30-min TTL) and reused. After 30 min it fails again with conf=0.00. Log shows "0.00 or 1.00, no inbetweens" — Vision returns binary.
- **mo (Moscow Oblast Court)**: `searchModuleUnavailable` is actually returning the **mo home page** (not search results). The classifier correctly says `.unrecognized` because the home page has no result markers. The diagnostic file confirms this. **This is a different bug — not encoding, not captcha. Wrong request URL or anti-bot.**
- **Komi/Syktyvkar form dumps**: noise. Form pre-check fires even on courts without captcha.

Recommended next round (v0.38.7) is to investigate **mo's home page response**:
1. Have user `rm` old diagnostic files, run a mo search, look at the new (clean) variant file.
2. Compare the URL `SudrfClient.runVariants` sent vs the URL a browser sends (and works).
3. Likely culprit: missing `delo_id`/`new` for mo, missing session cookie, anti-bot requiring specific headers (Referer, Origin), or mo requires POST.

## File map (current state)

```
Sources/CaptchaSolver/
  CaptchaKind.swift, CaptchaAttempt.swift, CaptchaConfiguration.swift,
  CaptchaSolvingProvider.swift, CaptchaSolver.swift, CaptchaSolverLog.swift,
  VisionOCRStrategy.swift, ImagePreprocessor.swift, Preprocessor.swift

Sources/SudrfKit/
  EncodingDetector.swift             — does NOT exist (deferred)
  SearchDiagnostics.swift            — v0.38.5 + v0.38.6 (raw bytes)
  SudrfClient.swift                  — v0.38.5 (fetchForm, dumpVariant) + v0.38.6 (fetchHTMLData)
  SearchPageClassifier.swift         — unchanged
  CaptchaDetector.swift               — unchanged
  Cyrillic1251.swift                  — unchanged

Sources/SudrfApp/
  AutoCaptchaSolver.swift            — v0.38.0 + v0.38.1 + v0.38.6 (lastPNG dump)
  RefreshCenter.swift                — v0.38.0 + v0.38.2 (tryAutoSolve via shared helper)
  SearchModel.swift                  — v0.38.1 (executeSearch + handleCaptcha)
  AppModel.swift                     — v0.38.2 (AppRouter captures + solver)
  CaptchaSettings.swift               — v0.38.4 (preprocessorHosts) + v0.38.5 (diagnosticsEnabled)
  CaptchaMenu.swift                   — v0.38.0
  SearchModel.swift (re-uses SearchModel.CaptchaContext)

Tests/CaptchaSolverTests/             — PreprocessorTests, CaptchaSolverLogTests, VisionOCRStrategyTests, AutoCaptchaSolverTests, CaptchaSolverTests, ImagePreprocessorTests
Tests/SudrfKitTests/                  — CaptchaImageExtractorTests, SearchDiagnosticsTests
Tests/SudrfAppTests/                  — CaptchaAssistTests, CaptchaPendingQueueTests, etc.
```

## Key invariants (must keep working)

- `CaptchaSettings.shared` is the **singleton** that all three call sites (AppRouter, RefreshCenter, SearchModel) read from. Changing its signature breaks all three.
- `SudrfClient.fetchHTML(_:) -> String` is the **public API**. Don't break it. New `fetchHTMLData` is private.
- `CaptchaImageExtractor.extract(html:)` returns `Optional<(png: Data, captchaid: String)>`. Used by all three call sites.
- `CaptchaTokenStore.shared` — singleton, 30-min TTL.

## How to continue the conversation

Suggested prompt to paste in a new session:

```
Working on /Users/arvidsever/Claude/Projects/Sudrf, branch captcha-auto-solver.
We've shipped v0.38.0–v0.38.6 (270 tests passing, all committed and pushed).

The remaining issue: oblsud--mo.sudrf.ru and sankt-peterburgsky--spb.sudrf.ru.
The diagnostic dump now writes raw bytes (v0.38.6 fix) so the next
search will produce a clean copy of whatever the server actually
returns. For mo, the variant file contains the mo home page, not
search results — the request URL or session is wrong.

Please read Sources/SudrfKit/SudrfClient.swift, look at runVariants
and the URL it constructs via SudrfURLBuilder, and figure out
why the request returns the home page. mo works in a browser, so
compare the URL the app sends vs the URL a browser sends.

Also: spb's "working" state is a 30-min cached token. The actual
captcha is unreadable to Vision (conf=0.00). After 30 min the user
will see the manual sheet again. Per-host preprocessor opt-in is
already wired (CaptchaSettings.preprocessorHosts); user just needs
to run `defaults write ru.sudrf.app captcha.preprocessorHosts -array
sankt-peterburgsky--spb.sudrf.ru` after enabling preprocessing globally.

Plan mode first. Read the recent diffs (last 7 commits) before
proposing changes. See the project AGENTS.md for full context on the
captcha auto-solver pipeline.
```

## Commits to know about (most recent first)

```
08f2c39  v0.38.6: diagnostic dump preserves raw bytes
fae6468  v0.38.5: diagnostic dump for searchModuleUnavailable
97b904a  v0.38.4: per-host preprocessor for rotated/struck-through captcha
a335049  v0.38.2: wire auto-solve into per-instance captcha stub
f77757a  v0.38.1: wire auto-solver into interactive SearchModel.runSearch
e8a19df  v0.38.0: auto-solver капчи (Vision, on-device)
b4e69d8  Fix VNKOD KAS appeal lookup           (codex-captcha-assist)
4cd62d5  Adopt alpha versioning scheme        (codex-captcha-assist)
06f5130  Document v37 magistrate release       (codex-captcha-assist)
```

`git log main..captcha-auto-solver --oneline` lists all 7 v0.38.x commits plus the 4 base commits off `codex-captcha-assist`.

## What the user will need to do on the new session

```bash
cd /Users/arvidsever/Claude/Projects/Sudrf
git status   # should be clean on captcha-auto-solver
swift test   # 270 tests passing
swift run SudrfApp  # try search on mo, then open the new diagnostic file
```

## Open question to flag in the new session

The user asked us to confirm one thing I didn't get to before plan mode: whether to bump or not. The "Mojibake fix" is shipped (v0.38.6). The actual mo bug is **not yet diagnosed** — the new diagnostic files will show the real problem. Next session should start by reading the new mo variant file from `~/Library/Application Support/Sudrf/diagnostics/`.

## Detailed context for the mo bug

To save time when resuming, here's what we already know:

1. mo's `searchModuleUnavailable` is correct error code, but the underlying cause is that the server returns the home page, not search results.
2. The mo diagnostic file (`oblsud--mo.sudrf.ru_20260709-125108-534_variant.html`) decodes cleanly as UTF-8 and shows the mo homepage structure (`<TITLE>Московский областной суд</TITLE>`, with menu links). Only 2 form inputs visible (`name`, `srv_num`).
3. The server's HTTP header is `Content-Type: text/html; charset=windows-1251` (from `curl -I`).
4. The user's URL for a working browser search would be `https://oblsud--mo.sudrf.ru/modules.php?name=sud_delo&...` — the app's `SudrfURLBuilder.searchURLVariants` should produce that.
5. The form pre-check dump (33 form files) is noise from a background polling loop.

**Likely causes to investigate** (in order of probability):
- Missing session cookie (PHPSESSID). Some mo-like courts require a session to be established by first GETting the form, then the POST/GET to results uses that session.
- Wrong `delo_id` for the chosen cartoteka. mo may have a different `delo_id` mapping.
- `Referer` or `Origin` header required (anti-bot). Check what the browser sends.
- Need to use a specific form URL before the search URL (the form pre-check is a separate request — maybe the variant URLs also need this).

## Detailed context for the spb bug

- spb's auto-solved conf=1.00 then reuses the token. The auto-solver works on the FIRST attempt because the captcha happens to be a "good" one for Vision.
- On subsequent runs (after token expires), conf=0.00. The captcha has rotated digits + strikethrough lines.
- Per-host preprocessor opt-in is the fix. User needs to enable globally and add the host:
  ```bash
  defaults write ru.sudrf.app captcha.preprocessorEnabled -bool YES
  defaults write ru.sudrf.app captcha.preprocessorHosts -array sankt-peterburgsky--spb.sudrf.ru
  ```
- The preprocessor (grayscale + contrast + 2x scale) was tested on synthetic captcha and didn't break the build. But for the saved spb fixture (the one with rotated digits), the test wasn't run live — only verified via the diagnostics folder for failure cases.

## Files to read first when resuming

In priority order:
1. `Sources/SudrfKit/SudrfClient.swift` — `runVariants` (line ~163) and `searchOnce` (line ~118). The mo bug is here.
2. `Sources/SudrfKit/SudrfURLBuilder.swift` — the URL builder. Compare with the user's browser URL.
3. `Sources/SudrfKit/SearchPageClassifier.swift` — what classifies the home page as `.unrecognized`. Should we add a home-page marker?
4. `~/Library/Application Support/Sudrf/diagnostics/oblsud--mo.sudrf.ru_*.html` (latest) — the actual server response. Read in browser or `iconv -f utf-8 file.html | less`.
