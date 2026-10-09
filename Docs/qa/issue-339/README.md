# Issue #339: acceptance status

## Test-only system publication boundaries

The approved test seam leaves normal `AppRouter` behavior unchanged: its defaults still publish `NSUserActivity` with `becomeCurrent()` and send feed notifications through `FeedNotifier.shared`. The #339 harnesses inject a test activity publisher, a count-only notification receiver, and a `SpotlightIndexer` backed by a no-op writer and suite-scoped stores. No system notification is delivered by those harnesses.

`FeedNotifier.setBadge` remains a separate Dock side effect. Every #339 test that constructs `AppRouter` now skips unless `NSApp == nil`; the app lifecycle hook that configures `UNUserNotificationCenter` is not invoked. The offline test also uses suite-scoped preferences, a temporary CAPTCHA corpus and log paths, and an instance-local token store.

This is code-level test isolation, not runtime acceptance. AppRouter-path tests and live acceptance have not been run after adding the notification receiver.

## Offline verification

`DirectCaseLinkSheetTests.testConfirmDirectLinkContinuesTwoCaptchasAfterSheetClosesAndSurvivesColdReopen` exercises the supported import and refresh lifecycle without contacting a court portal. The test resolves the existing #321 direct-card fixture through a stub fetcher, passes the result to `AppRouter.addDirectCaseLink`, and supplies scripted movement responses and CAPTCHA results.

The first import uses a temporary on-disk store. The test asserts that adding a record with no cached movement starts refresh synchronously, then awaits the already-started task. It checks the confirmed subject-court card, the partial source outcome, and removal of CAPTCHA placeholder instances after the scripted empty response. It releases the first store/router/container scope before opening a new container for the same store URL.

Before the repeated import, the reopened store must match the full saved state, including collection membership, `seenAt`, movement instances, source-attempt kind, and exact journal event IDs. Reopening an already tracked case through `addDirectCaseLink` intentionally marks it seen; the test captures that timestamp immediately after import and checks that the repeated refresh preserves it and the exact event journal. The refresh after this cached reopen is explicit because opening a record with saved movement does not auto-start another refresh.

The approved harness preserves the real add-and-refresh path while replacing its activity, Spotlight, and notification publication sinks. The current local gate is compile-only; do not run the AppRouter-path tests as part of this checkpoint.

```sh
swift test --filter DirectCaseLinkSheetTests
```

## Opt-in live acceptance: prepared, not run

No live request has been made from this branch. The live test is skipped unless `SUDRF_ISSUE339_LIVE_ACCEPTANCE=1` is present in the XCTest process. It fails immediately if the process bundle identifier is `ru.sudrf.app`, skips if `NSApp` is available, and skips if automatic CAPTCHA solving is disabled in the test process.

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
