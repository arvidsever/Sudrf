# Treasury RSS journal — #454

Source and disk checks recorded on 10 October 2026. Synthetic fixtures only;
no live Treasury response is claimed. This is the separate prerequisite for
#179; the production feed still uses its existing RSS presentation.

## Implemented contract

- A nonempty published RSS GUID binds an immutable event to the logical case.
  A changed title, date or ordering does not create another event.
- Preparation quietly backfills persisted RSS history. Existing journal IDs,
  collections and case read state remain intact.
- Native Treasury refresh and manual FSSP persistence use the existing store
  transaction: source records, journal append and save succeed or roll back
  together. The record is resolved again after the network wait.
- A proven dossier merge keeps the survivor's GUID binding and retains retired
  event IDs as aliases. Court journals and their baseline conflict policy use
  the existing merger. Missing GUIDs are not reconstructed.
- Optional fields live in the existing journal JSON. SwiftData schema and the
  public source API remain unchanged.

## Verified

The ten new `TreasuryEventJournalTests` run with synthetic data and temporary
disk stores. The native-client test uses an ephemeral URLProtocol session,
disabled cookies/cache, private court client stores and rejecting unused court
providers. Conditional construction of injected RefreshCenter clients reuses
the already reviewed #241 pattern; ordinary defaults are preserved.

Result: **10 tests, 0 failures, 0 skips**. Final local log:
`/private/tmp/sudrf-454-notifications.log`; SHA-256
`9e43d63203154752ff483043a80740bdf6450f182fd07cf8d2c0bc7919b27e61`.

Covered: GUID identity, changed presentation, duplicate/reordered RSS, malformed
GUIDs, FSSP exclusion, old history backfill, restart/replay, real native
TreasuryClient → RefreshCenter → disk, real atomic dossier merge/reopen,
survivor and retired IDs, collections, court events and compatible baselines,
and journal append/encoding/save failure rollback. A combined preparation
save failure also restores both Moscow normalization and RSS backfill, including
retained model objects and reopened disk contents.

The tenth test runs the existing AppRouter feed and notification filter with
private settings, tokens, clients, corpus and act cache. Spotlight, activities,
intent installation and dock badge effects are replaced; the notification
publisher records submissions in a private receiver. The DI-only AppModel
parameters reuse the reviewed #250 pattern and retain ordinary defaults.
Persisted history is quiet; the first real synthetic fetch announces its new
GUIDs once. Repeating while they remain unread does not announce them again.
Read/known IDs of a deleted duplicate transfer through the actual disk merge
and existing RefreshCenter remap callback; the V6 survivor key stays permanent.
Reopening the merged store retains read state and causes no new submission.
This proves submission/filtering, not macOS notification delivery. No native
application, AppBootstrap, background scheduler or live network was used.

An additional existing-class profile ran 152 tests without failures (7 Kit,
85 RefreshCenter, 52 repair and 8 new journal tests). That broad profile is
**not an isolation proof**: some older tests construct default dependencies
and access shared settings. `RefreshCenterTests` temporarily writes CAPTCHA
autoSolve/minConfidence/maxAttempts and restores effective values, without
restoring absent keys. Two existing tests construct AppRouter, whose reload may
write known/read/material-migration feed preferences without a prior snapshot.
It is not established whether these values changed or whether the XCTest
defaults domain equals the installed app domain. Log `/private/tmp/sudrf-454-focused.log`, SHA-256
`c49f597f3d00d9bd6ff1d12da1054eaefed3e5a093443eddac98623122ae3367`.
A subsequent full local suite was stopped (exit 130) during Kit parser tests
after this boundary was identified. Do not rerun the broad suite locally or
restore shared settings without a known prior value; run the full suite in CI.
Default test-process constructors also create common diagnostic/corpus
directories, read corpus manifests and construct VS RF/Moscow clients with
shared cookie storage. Lazy court-client/variant-cache constructors alone do
not prove network or cache access. AppRouter installs its normal intent/open
hooks and invokes the badge callback, while its non-notifying reload does not
submit notifications or indexing. Effects on installed-app preferences are
not established. No installed application or working database was opened.

## Remaining gates

- Independent review passed for the source and all ten isolated tests;
  registry verification and project generation passed. The own Xcode Debug
  build succeeded without launching the app: `/private/tmp/sudrf-454-native-build.log`,
  SHA-256 `f7782742eb2a45bfcc2d268ebe4f962ce2c3b9f4a1b423d94d97ac2b5010a544`.
  At this historical source checkpoint current-head CI and version assignment
  were pending; implementation CI and release preparation are recorded below.
- Changelog/history/release table are prepared at the actual merge order below.
  Keep #454 open until final current-head CI and release gates pass.

## Implementation CI and release preparation — 10 October 2026

Actual main remains `7f869f10d8ab540df20f974c72def39060a0289e`, version
0.65.1 (262). Release metadata is prepared as patch 0.65.2 (263), after #455.
Implementation head `12e85fdf4138a333840680b510aba3929f87265a`,
[CI 38061683521](https://github.com/arvidsever/Sudrf/actions/runs/38061683521),
passed: 2113 XCTest, 21 skips, zero failures; 28 Swift Testing; 27 Python,
six skips. All ten TreasuryEventJournalTests actually executed and passed,
including real native-client disk/replay and actual isolated feed/notifier
submission filtering through merge/reopen. No OS notification delivery is claimed.
Full log `/private/tmp/sudrf-454-ci-12e85fd.log`, SHA-256
`5f16d9d05dc9b8da6bb6149475f03edd86f419efe075fc3f065e36e78451fbe2`.
App, CLI, registry, model resources and packaging passed. Conditional hosted
Xcode 27 build/test steps were skipped; own native build remains separate evidence.
Independent Astra release review passed for all nine status paths (eight files
after draft-to-release rename). Final release-head CI and own native build263
remain pending;
no release push or merge has been performed at this checkpoint.
Open-issue inventory before closing #454 is 50; closing it leaves 49. #179
remains open and its full cutover is not part of this release.
