# Issue #339: acceptance status

## Current result — 10 October 2026

Issue #339 remains open and PR #446 remains draft. The offline AppRouter path is now executed, not only compiled: hosted run [37994371778](https://github.com/arvidsever/Sudrf/actions/runs/37994371778) on `752cfc0ad7e30ed71d3466ab63b1a861fd8c4f92` passed all six focused `DirectCaseLinkSheetTests`, with zero skips and zero failures, in a fresh process. The unchanged full suite passed 2,038 XCTest cases (25 skips, zero failures), 28 Swift Testing cases and 26 Python cases (six skips). The full-suite skips do not replace the separate six-test gate.

Hosted log SHA-256: `142a67c4506c35b206704a80da86a193b7195b0257b831bb6a42821f95b8bcd8`. Own Xcode 27 build on the same head succeeded without launch; log SHA-256: `45ca6a047724e6c9ef0092fc5660a9858dde9905a9df82f7775eb8ce4619e986`. The registry generator reported the checked-in resource current.

Before local live execution, independent review found eager creation of the production diagnostics directory when installing a test override. Commit `717ffbd78f4ce73b913c80ba00cda489b9996fc5` changes initialization to URL-only and creates the selected directory at write time. Eight focused SearchDiagnostics tests passed without skips; log SHA-256: `36a89fe9c8191ea7f4a2812367a8f3b28f14f17c693407492077a5ac946b14d0`. Independent review: Ship for one selected opt-in live method.

One local live attempt on that head ran from 21:54:34 UTC to 21:54:58 UTC on 9 October 2026 (10 October in Moscow), taking 24.679 seconds. It stopped **before add/refresh** at the harness assertion comparing the requested and effective card locators. The assertion compares the entire `SudrfCaseCardLink`, including URL spelling. The effective locator was not retained in this attempt, so the cause of the mismatch is **not established**: neither a transport-only redirect nor changed source identity is proven. CAPTCHA continuation, refreshed movement and cold reopen were not reached. The local log SHA-256 is `44d27d407012f1b6f9165ef39c8fc933a4f3509f07c7290b191c501d8a3002c5`; raw logs and diagnostic files are not published.

A second, separately identified diagnostic attempt on `5cfd85c7eee0b442d100d2fc4f095ec6fc193564` completed successfully: one selected test, zero failures and zero skips, 467.365 seconds. Its private locator record was written at 22:01:30 UTC on 9 October 2026. This **second response** upgraded HTTP to HTTPS while preserving every compared source identity field and the ordered unknown query parameters; it does not establish what happened in the unsaved first response.

The unchanged production solver ran twice and returned two tokens, one each for `sankt-peterburgsky--spb.sudrf.ru` and `3kas.sudrf.ru`. For each host, the test required later confirmed native-card coverage or verified empty search, without residual CAPTCHA/source failure at that host. One record and two movement instances persisted; cold reopen compared the saved state exactly. Overall outcome was `.partial`, so this is evidence for the two CAPTCHA continuations and persistence, **not a complete-chain success**. Timings: resolver 24,319 ms; refresh 443,017 ms; solver 73,877 ms; cold reopen 2 ms. No automatic third live attempt was made.

Second run log SHA-256: `de380c54c99fb4e91e1a0985b45c2fe30693d075620c6b5d2f78b3bd72de4854`. Private locator diagnostic SHA-256: `80103bcb3db1dfced00f82611c5c0b7df81bee6d74527d3261e544e8d4ca215a`; observed directory mode `0700`, file mode `0600`. Requested/effective URLs, CAPTCHA values, tokens, cookies and raw responses are not published. Two pure test-only locator comparison tests passed before this attempt, including identity conflicts and unknown parameter preservation; log SHA-256 `00ce4aeedc0f9fe1689a939eec3f622f37081d50c23f6171108bb31c69548592`. The production link parser/equality and resolver were not changed.

Own Xcode 27 build after the diagnostics writer fix passed without launch; log SHA-256 `cb50a3fd69e4f40e424af5bdc46af450dfa3bcc03318eb0e1e2822c83913935e`. The subsequent locator change is test-only. Hosted CI [37997870822](https://github.com/arvidsever/Sudrf/actions/runs/37997870822) passed on `013adf3dd5c93918356b000297d6dcc8f027d0d4`: all six focused sheet tests executed without skips; full suite 2,041 XCTest cases (25 explicit skips, zero failures), 28 Swift Testing cases, and 26 Python cases (six skips). Log SHA-256: `abbe39e3f37a3b421b88f7f1b44296e373b172aeaa686e0a6d48f164912ad8cf`. This run predates the separate native QA host below; its final commit needs current-head CI before merge.

Native SwiftUI sheet, pasteboard and visual acceptance remain pending. No ordinary application, TestFlight or working store was opened. The sections below retain the harness contract and earlier checkpoints; their compile-only holds describe earlier stages, not the current six-test result.

## Native QA preparation — 10 October 2026

`build-ui.sh` builds the unchanged `DirectCaseLinkSheet` with an isolated native host and a generated seven-site AppModel overlay. The bundle is `ru.sudrf.qa.issue339`; storage, settings, tokens, logs and caches are temporary, providers are synthetic, and publication receivers are disabled. The actual sheet source hash is checked before generation.

Independent review caught and corrected three native-specific boundaries before launch: external links are discarded through the QA view environment; the production sandbox migration resource is excluded; production intent actions and shortcuts are excluded. A clean rebuild asserts absence of `container-migration.plist`, empty intent/shortcut metadata, no URL schemes, and actual signed sandbox entitlements with network and selected-file access disabled. These safeguards are QA-only; production files and interface are unchanged.

The clean own Xcode build passed. Build log SHA-256: `032b4e7a8152184aeacbbf82b87eb5995dd1aef4f80427164688307428b0da67`; binary SHA-256: `7bdb09fcd4a70a0cd55861562a09a2a009d22adbb1241d5db3bcfcb4912d5538`. Independent artifact recheck: Ship for requesting launch permission. **At that preparation checkpoint, the QA app had not been launched.** The later native runtime and accepted screens are recorded below; pasteboard remains a separate criterion; synthetic providers do not stand in for the separately recorded live CAPTCHA run.

## Test-only system publication boundaries

The approved test seam leaves normal `AppRouter` behavior unchanged: its defaults still publish `NSUserActivity` with `becomeCurrent()` and send feed notifications through `FeedNotifier.shared`. The #339 harnesses inject a test activity publisher, a count-only notification receiver, and a `SpotlightIndexer` backed by a no-op writer and suite-scoped stores. No system notification is delivered by those harnesses.

`FeedNotifier.setBadge` remains a separate Dock side effect. Every #339 test that constructs `AppRouter` now skips unless `NSApp == nil`; the app lifecycle hook that configures `UNUserNotificationCenter` is not invoked. The offline test also uses suite-scoped preferences, a temporary CAPTCHA corpus and log paths, and an instance-local token store.

The six offline AppRouter tests have now executed in the isolated hosted process described above. Live and native UI acceptance remain separate criteria.

## Offline verification

`DirectCaseLinkSheetTests.testConfirmDirectLinkContinuesTwoCaptchasAfterSheetClosesAndSurvivesColdReopen` exercises the supported import and refresh lifecycle without contacting a court portal. The test resolves the existing #321 direct-card fixture through a stub fetcher, passes the result to `AppRouter.addDirectCaseLink`, and supplies scripted movement responses and CAPTCHA results.

The first import uses a temporary on-disk store. The test asserts that adding a record with no cached movement starts refresh synchronously, then awaits the already-started task. It checks the confirmed subject-court card, the partial source outcome, and removal of CAPTCHA placeholder instances after the scripted empty response. It releases the first store/router/container scope before opening a new container for the same store URL.

Before the repeated import, the reopened store must match the full saved state, including collection membership, `seenAt`, movement instances, source-attempt kind, and exact journal event IDs. Reopening an already tracked case through `addDirectCaseLink` intentionally marks it seen; the test captures that timestamp immediately after import and checks that the repeated refresh preserves it and the exact event journal. The refresh after this cached reopen is explicit because opening a record with saved movement does not auto-start another refresh.

The approved harness preserves the real add-and-refresh path while replacing its activity, Spotlight, and notification publication sinks. The earlier compile-only checkpoint has been superseded by the six-test isolated hosted execution gate above.

```sh
swift test --filter DirectCaseLinkSheetTests
```

## Opt-in live harness and boundaries

The first attempt and its unresolved locator criterion are recorded above. The live test is skipped unless `SUDRF_ISSUE339_LIVE_ACCEPTANCE=1` is present in the XCTest process. It fails immediately if the process bundle identifier is `ru.sudrf.app`, skips if `NSApp` is available, and skips if automatic CAPTCHA solving is disabled in the test process.

The live path uses the existing sanitized #321 locator with `DirectCaseLinkResolver`, then calls `AppRouter.addDirectCaseLink` and joins the refresh task that this method must already have started. The test uses the production `CaptchaSolverFactory` and its unchanged provider selection. The factory now accepts an internal logger argument defaulting to `.shared`; live tests inject a temporary `CaptchaSolverLog`, and a focused test asserts that the factory returns a solver holding that exact logger.

The court client uses an ephemeral URL session, `WorkingVariantStore(cacheURL: nil)`, and an instance-local `CaptchaTokenStore`; no shared token entries are read, cleared, or restored. The live test reads the process auto-solver setting once, then copies that value into suite-scoped `CaptchaSettings`. CAPTCHA attempts use a per-challenge maximum of three. `SearchDiagnostics` is redirected to the temporary run area and restored afterward. The store, CAPTCHA corpus, settings, and Spotlight manifest/preferences use test-owned temporary locations. Raw solver and search diagnostics remain local in the temporary run directory; do not attach them to QA reports or pull requests.

The movement provider also injects `DistrictCourtResolver(client: sameClient, cacheURL: nil)` through `MovementService`'s existing `transferCourts` initializer. The harness observes only fresh source-coverage summaries. A token-returning host must have a later movement result proving either a loaded native card admitted against the source coverage or a verified empty listing, with no remaining CAPTCHA or source failure for that host.

The test does not bootstrap background work, query FSSP or Treasury, use the working database, or call `AppRouter.resolveDirectCaseLink`. That wrapper owns its default client, so the resolver is exercised directly with the isolated client and its result is passed to `addDirectCaseLink`. The test receiver substitutes for both `NSUserActivity` publication and feed-notification delivery; it records the activity type and notification-entry count without retaining case text or identifiers. `SpotlightIndexer` uses the harness's no-op writer. The unchanged production publishers remain the defaults outside these tests.

The test cold-reopens the temporary disk store in a new `ModelContainer` and checks exact saved state without importing a second time. It records only stage durations, source-host counts, outcome labels, and short SHA-256 digests. It never prints OCR values, CAPTCHA tokens, cookies, full locators, or participant data.

Even a successful live component test does not exercise the native SwiftUI sheet, pasteboard handling, or visual confirmation. Those UI criteria remain pending and must not be reported as covered by model/component tests.

## Local checkpoint (9 October 2026)

Earlier static review accepted three test-only corrections:
CAPTCHA token restoration now preserves pre-existing canonical-host entries,
the transfer resolver uses the same isolated client with no disk cache, and a
solved host counts as confirmed only after later fresh-card or verified-empty
coverage with no unresolved source failure or CAPTCHA.

The focused factory test
`DirectCaseLinkLiveAcceptanceTests.testFactoryPassesSuppliedLoggerThroughUnchangedProviderSelection`
previously passed 1/1. The notification publisher seam and its receiver have
only been compile-checked in this continuation; neither the AppRouter-path
sheet test nor the opt-in live test has been executed. No live request or
full-suite run is claimed. Native sheet and visual criteria remain untested.

## Approved isolation checkpoint, 10 October 2026

The author approved the test-only activity, Spotlight and notification substitutions and temporary solver logger. Production defaults remain unchanged. The previous activity-publication hold is resolved by the injected publisher; runtime checks are still a separate gate.

`swift build --build-tests` completed successfully after the notification seam. Log: `/private/tmp/sudrf-339-notification-compile.log`; SHA-256 `3dfd34b4721566be30c51e405772d8862afb460e5cfacf637cabb562c60105b6`. Independent static review of this delta: Ship. No AppRouter-path test or live request was executed locally.

The default `PublishedActSelection` cache only stores its directory URL at initialization. File-system reads/writes occur when an act is selected or saved; these harnesses do neither. The opt-in test's single auto-solver preference read belongs to the XCTest process, then suite-scoped settings are used. This checkpoint does not claim zero access to process defaults.

## Current-main rebase checkpoint

Rebased onto main `e9910a36b9d1af09d82de3f2eeaba246573a6cca` (0.64.5, build 257). The two conflict sites retain main's injected VSRF/import providers and the approved CAPTCHA token/solver seams together. All test targets compiled successfully without execution: `/private/tmp/sudrf-339-rebased-compile.log`, SHA-256 `e109692f1b459e4e62f0fa502cea061d92ac38b8f68698e22c2b43aa750826ac`. Runtime offline evidence must come from current-head CI and must show actual test execution rather than skips.

## Focused hosted execution gate

Full CI run `37992365897` passed on `f82c4a17259b2fa0a8d8de078bfef12a31e3423e`: 2,022 XCTest cases, 25 skipped, zero failures, plus 28 Swift Testing cases. Four AppRouter paths in `DirectCaseLinkSheetTests` were skipped because earlier tests had created `NSApp`; this run does not satisfy their acceptance.

The stable hosted job now starts this six-test class in a fresh process before the full suite. The step requires every named test to report `passed` and rejects any skip; its log gate was checked with six passes, a missing pass and a skipped case. The three offline refresh paths also disable the existing `recoverCard` callback, so a fixture failure cannot reach the default network client. Production card recovery is unchanged.

All test targets compile after this adjustment. Log: `/private/tmp/sudrf-339-focused-gate-compile.log`; SHA-256 `172183a26b3ccfb870def1b12db574c1c06b52ef1a48ae44d69c42c865a447e1`. Focused runtime results remain pending until the new hosted run finishes. No local AppRouter execution or new live request is claimed.

Own Xcode 27 build on `f82c4a1` succeeded without launch: `/private/tmp/sudrf-339-current-xcodebuild.log`; SHA-256 `122eafc061750b6bdfb2713c5d9fbf26a563a6b174a0e47e807ded7839317115`. The later adjustment touches only tests and CI.


## Native offline runtime checkpoint - 10 October 2026

The isolated QA product was rebuilt from head
`1f26560af69c5d8eba99b0ef9aebc3c2a811101c` in the restored existing branch.
Bundle guard and signed bundle ID match `ru.sudrf.qa.issue339`; sandbox/network
and file-access restrictions, no migration/URL schemes/intents, private
settings/storage/providers and publication substitutions were rechecked.
Build log SHA-256: `22b619e888a2dcfebbea6592a4eb2e0bfd5ac4e1155ab1f3754e8183b09ff3cb`. Preparation did not launch the product.

During the subsequent root CUA session, the real direct-link sheet resolved the
synthetic test URL for case 12-538/2026. Add opened the real CaseMovementView
after the two scripted CAPTCHA continuations. Root CUA emitted the form and movement-card screenshots, then quit
Sudrf339QA through Activity Monitor; the subsequent CUA inventory contained no
running QA applications. Root repeated only the own QA capture to save the
actual CUA JPEGs, then quit the QA app again; CUA inventory again contained no
running QA applications. On 10 October 2026 the user accepted both screens
with the explicit reply: "Да, оба экрана приняты".
These are synthetic native UI observations, not a new live-source attempt or
a full live-chain success. The earlier separate live component evidence retains
its partial outcome and its own boundaries.


Accepted native offline screenshots (actual CUA captures, synthetic QA data):

- [Direct-link form](screenshots/issue-339-native-form.jpg).
- [Movement card](screenshots/issue-339-native-card.jpg).

These two screens and the observed offline add route are accepted. Pasteboard
behavior was not separately verified; this approval does not expand the earlier
live component result into full live-chain acceptance.

Original capture paths and SHA-256:
- `/Users/arvidsever/.codex/visualizations/2026/09/26/01a0dd3e-f51f-73a3-94a6-d6008364562e/issue-339-native-form.jpg`: `cb2c67fa1986fc54e7eccfa4c5d708d89ecc85ed7abf7ff39139266b55c342d4`.
- `/Users/arvidsever/.codex/visualizations/2026/09/26/01a0dd3e-f51f-73a3-94a6-d6008364562e/issue-339-native-card.jpg`: `7e280d26c04ae2acb85d6583fee883b2581f25aaeae9cf1c2957b36e8c9fad2c`.
