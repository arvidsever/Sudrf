# Issue #339: acceptance status

## Hold: AppRouter search activity

The offline sheet test and live harness call `AppRouter.addDirectCaseLink`. Its normal open path briefly publishes a search-eligible `NSUserActivity` with `becomeCurrent()`. Root review has put further runs of these paths on hold overnight. Do not rerun `DirectCaseLinkSheetTests` or opt into the live test until the pending morning product decision is resolved.

Pending decision: may the tests use a narrow internal seam to suppress that activity publication while keeping the normal import and refresh path? No seam has been added. The earlier focused pass predates this isolation finding and is not a current acceptance result.

## Offline verification

`DirectCaseLinkSheetTests.testConfirmDirectLinkContinuesTwoCaptchasAfterSheetClosesAndSurvivesColdReopen` exercises the supported import and refresh lifecycle without contacting a court portal. The test resolves the existing #321 direct-card fixture through a stub fetcher, passes the result to `AppRouter.addDirectCaseLink`, and supplies scripted movement responses and CAPTCHA results.

The first import uses a temporary on-disk store. The test asserts that adding a record with no cached movement starts refresh synchronously, then awaits the already-started task. It checks the confirmed subject-court card, the partial source outcome, and removal of CAPTCHA placeholder instances after the scripted empty response. It releases the first store/router/container scope before opening a new container for the same store URL.

Before the repeated import, the reopened store must match the full saved state, including collection membership, `seenAt`, movement instances, source-attempt kind, and exact journal event IDs. Reopening an already tracked case through `addDirectCaseLink` intentionally marks it seen; the test captures that timestamp immediately after import and checks that the repeated refresh preserves it and the exact event journal. The refresh after this cached reopen is explicit because opening a record with saved movement does not auto-start another refresh.

After the activity-publication decision, the offline test can be run with:

```sh
swift test --filter DirectCaseLinkSheetTests
```

## Opt-in live acceptance: prepared, not run

No live request has been made from this branch. The live test is skipped unless `SUDRF_ISSUE339_LIVE_ACCEPTANCE=1` is present in the XCTest process. Root isolation review is still required before setting it. The test also fails immediately if the process bundle identifier is `ru.sudrf.app`, and skips if automatic CAPTCHA solving is disabled in the test process.

The live path uses the existing sanitized #321 locator with `DirectCaseLinkResolver`, then calls `AppRouter.addDirectCaseLink` and joins the refresh task that this method must already have started. The test uses the production `CaptchaSolverFactory` and its unchanged provider selection. The factory now accepts an internal logger argument defaulting to `.shared`; live tests inject a temporary `CaptchaSolverLog`, and a focused test asserts that the factory returns a solver holding that exact logger.

The court client uses an ephemeral URL session, `WorkingVariantStore(cacheURL: nil)`, and the process-local `CaptchaTokenStore.shared`. The test snapshots and clears relevant token entries before the request, excludes already captured canonical hosts from its second snapshot, then restores tokens on success or thrown failure. CAPTCHA attempts use the user's read-only settings with a per-challenge maximum of three. `SearchDiagnostics` is redirected to the same temporary run area and restored afterward. The store and corpus use that temporary directory. The raw solver and search diagnostics remain local in the temporary run directory; do not attach them to QA reports or pull requests. `AppRouter` initialization may create the standard Sudrf CAPTCHA diagnostic directories, but the active refresh uses the injected temporary logger.

The movement provider also injects `DistrictCourtResolver(client: sameClient, cacheURL: nil)` through `MovementService`'s existing `transferCourts` initializer. The harness observes only fresh source-coverage summaries. A token-returning host must have a later movement result proving either a loaded native card admitted against the source coverage or a verified empty listing, with no remaining CAPTCHA or source failure for that host.

The test does not bootstrap background work, query FSSP or Treasury, use the working database, or call `AppRouter.resolveDirectCaseLink`. That wrapper owns its default client, so the resolver is exercised directly with the isolated client and its result is passed to `addDirectCaseLink`. The router's normal open path briefly publishes a search-eligible `NSUserActivity`; the test closes the case after refresh. This transient activity is distinct from `SpotlightIndexer`, which is suppressed through a restored XCTest-process preference. Root isolation review must assess this component side effect before any live run.

The test cold-reopens the temporary disk store in a new `ModelContainer` and checks exact saved state without importing a second time. It records only stage durations, source-host counts, outcome labels, and short SHA-256 digests. It never prints OCR values, CAPTCHA tokens, cookies, full locators, or participant data.

Even a successful live component test does not exercise the native SwiftUI sheet, pasteboard handling, or visual confirmation. Those UI criteria remain pending and must not be reported as covered by model/component tests.

## Local checkpoint (9 October 2026)

Astra's independent review accepted the three latest test-only corrections:
CAPTCHA token restoration now preserves pre-existing canonical-host entries,
the transfer resolver uses the same isolated client with no disk cache, and a
solved host counts as confirmed only after later fresh-card or verified-empty
coverage with no unresolved source failure or CAPTCHA.

The focused factory test
`DirectCaseLinkLiveAcceptanceTests.testFactoryPassesSuppliedLoggerThroughUnchangedProviderSelection`
passed 1/1. The AppRouter-path sheet test and the opt-in live test were not run
while `NSUserActivity.becomeCurrent()` isolation is on hold. No live request or
full-suite run is claimed in this checkpoint; the native sheet and visual
criteria remain untested here.
