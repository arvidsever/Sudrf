# #179 — compatibility inventory

This is a **compatibility inventory, NOT a passed downstream shadow gate or
cutover**. It checks selected existing pure contracts using synthetic values.
It does not compare complete rendered feeds, deliver notifications, or change
the active feed, unread state, or badges.

## Checked contracts

| Existing behavior | Exercised implementation | Result represented by the focused tests |
| --- | --- | --- |
| Issue #99: a dated clerical movement with a time is not a hearing; legacy feed identity migration drops the old kind segment. | `CaseLifecycleResolver`, `MovementDerivation.futureHearings`, `AppRouter.feedID`, `AppRouter.feedIDDroppingKind`. | The clerical row is absent from future hearings, a real hearing remains recognized, and the old ID normalizes to the current legacy ID. |
| The pure recent-entry helper includes non-future entries inside its requested window. | `CaseEventDeriver`, `AppRouter.recentFeedEntries`. | A future hearing exists in the semantic derivation while a six-day entry is included and a future or seven-day-boundary entry is excluded for `days: 7`. |
| The first v6 semantic baseline is quiet; partial coverage does not advance it; a complete confirmed change is recorded once. | `CaseEventBaselineTransition.refresh`, `CaseEventDeriver`, `CaseEventJournal.append`. | A synthetic past session seeds without an event, an incomplete judge change leaves the baseline unchanged, and the complete change creates one `judgeChanged` event; repeating the same complete snapshot creates none. |
| Journal event identity is semantic and independent of the legacy feed ID and presentation evidence. | `CaseEventDeriver`, `AppRouter.feedID`. | Independently deriving the same published act with reformatted title/court labels yields the same journal ID but different evidence; the act ID remains distinct from the legacy feed ID. Transitioning an already-known act to the reformatted observation emits no new act event. |
| Treasury RSS identity remains GUID-based and read filtering still follows the existing unread flag. | `AppRouter.enforcementFeedID`, `AppRouter.filteredFeedEntries`. | Toggling unread state does not change the GUID identity; the existing unread filter includes the unread item and excludes the read item. |
| Existing material-feed read and known IDs migrate to the source-specific row once, without becoming a wildcard for a later unrelated card. | `AppRouter.materialFeedTransitionsToMigrate`, `AppRouter.migratedFeedIDs`. | The test asserts the alias is consumed, then repeats with retained legacy IDs in both sets and checks both helper outputs exclude the later second card. A separate known-only case migrates the known ID while keeping the read-ID result empty. |
| Adding a published instance number to an already-known native card is not a new semantic case event. | `CaseEventDeriver`. | A synthetic observation's number-only enrichment under the same source-card ID emits no journal event. |

The tests call pure helpers and the real semantic deriver, baseline transition,
and journal. They do not instantiate `AppRouter` or read persisted state.

## Not established here

- The old renderer is assembled in `AppModel.reload` from stored sessions,
  acts, and Treasury entries. This checkpoint does not duplicate that renderer
  or prove row-for-row parity against a journal projection.
- `AppModel.reload` applies its own inclusive 45-day feed boundary. That
  renderer boundary is not tested here; `recentFeedEntries(days:)` is a
  separate pure helper and the test covers only its seven-day contract.
- Read/known migration in the full reload lifecycle, notification
  eligibility/delivery, badge counts, deduplication across reloads, and user
  preference behavior are not exercised. The focused material transition
  helpers do not establish production reload parity.
- Future hearings and newly derived judge changes remain shadow-only. This
  checkpoint does not authorize user-facing notifications or a feed cutover.
- Treasury remains an independent RSS/GUID feed contract in this inventory;
  it is not projected into `CaseEventJournal` here.

These gaps require a later downstream comparison and explicit acceptance before
changing the feed, notifications, or badges. No production code or user-facing
behavior changes in this checkpoint.

## Focused verification

Focused result on **9 October 2026**: **5 tests, 0 failures**. The isolated
scratch tree was `/private/tmp/sudrf-179-reviewfix.dksfuO`, with module cache at
`/private/tmp/sudrf-179-reviewfix.dksfuO/module-cache` and Clang module cache at
`/private/tmp/sudrf-179-reviewfix.dksfuO/clang-cache`. This is not a full-suite,
CI, or application-build gate. The command did not launch the application,
open SwiftData, or access a working database.

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/sudrf-179-reviewfix.dksfuO/module-cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/sudrf-179-reviewfix.dksfuO/clang-cache \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --disable-sandbox --skip-update \
  --scratch-path /private/tmp/sudrf-179-reviewfix.dksfuO/build \
  --filter CaseEventFeedCompatibilityTests
```

Independent review accepted this test-only checkpoint after correcting the
recent-helper boundary, exercising the real act deriver, and strengthening
material read/known migration. Root repeated the focused run on 9 October
2026: **5 tests, 0 failures**. Local log:
`/private/tmp/sudrf-179-root-focused.log`, SHA-256
`9815519a4a91c24bd246ca575569ae6c9df0c5baa2859f1910424c12f907026b`.
Test source SHA-256:
`981518a04cc4c67b5bbef2c662885eb0474ab93100b0e35a3f50150ecf66802c`.
This does not establish the deferred downstream shadow gate.
