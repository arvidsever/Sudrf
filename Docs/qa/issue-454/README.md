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

The nine new `TreasuryEventJournalTests` run with synthetic data and temporary
disk stores. The native-client test uses an ephemeral URLProtocol session,
disabled cookies/cache, private court client stores and rejecting unused court
providers. Conditional construction of injected RefreshCenter clients reuses
the already reviewed #241 pattern; ordinary defaults are preserved.

Result: **9 tests, 0 failures, 0 skips**. Final local log:
`/private/tmp/sudrf-454-isolated-final.log`; SHA-256
`e6065f410a5cb5b5ba9cfeb1b6349353e554bbf4efeaf0456afd45923ec35ca6`.

Covered: GUID identity, changed presentation, duplicate/reordered RSS, malformed
GUIDs, FSSP exclusion, old history backfill, restart/replay, real native
TreasuryClient → RefreshCenter → disk, real atomic dossier merge/reopen,
survivor and retired IDs, collections, court events and compatible baselines,
and journal append/encoding/save failure rollback. A combined preparation
save failure also restores both Moscow normalization and RSS backfill, including
retained model objects and reopened disk contents.

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
No installed application or working database was opened.

## Remaining gates

- Actual AppRouter known/read filtering and notification submission through a
  private receiver. A successful RefreshCenter callback is not this proof.
  Reuse the private dependencies prepared in #250 rather than a second feed
  implementation; do not cut the production feed over in this issue.
- Final independent review, registry/project generation, native build and
  current-head CI. No release version is assigned yet.
- Changelog/history/release table at the actual merge order. Keep #454 open
  until the remaining preservation and notification criteria pass.
